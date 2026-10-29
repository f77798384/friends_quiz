import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm";

const cfg = window.QUIZ_CONFIG || {};
const configured = cfg.SUPABASE_URL && cfg.SUPABASE_ANON_KEY &&
  !cfg.SUPABASE_URL.includes("YOUR-PROJECT") && !cfg.SUPABASE_ANON_KEY.includes("YOUR_SUPABASE");
const $ = (id) => document.getElementById(id);
const supabase = configured ? createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY) : null;
let session = { room: null, player: null, isHost: false };
let roomData = null, players = [], myQuestions = [], allQuestions = [], answers = [], results = [];
let currentView = "home", busy = false;
let gradingQueue = [];
let lastQuestionType = "single";
let textAnswersByType = {fill:"",short:""};
let choiceDraft = null;
// 作答草稿必須在可能觸發 refreshAll() 的工作階段恢復前初始化。
let answerDraft = {};
const SESSION_KEY="friends_quiz_tab_v4";
function saveTabSession(){try{sessionStorage.setItem(SESSION_KEY,JSON.stringify({room:session.room,player:session.player,isHost:session.isHost,code:$("roomCode").value,nickname:$("nickname").value,view:currentView}));}catch{}}
function clearTabSession(){try{sessionStorage.removeItem(SESSION_KEY);}catch{}}
function resetToSetup(message="已離開房間"){
  clearTabSession();session={room:null,player:null,isHost:false};roomData=null;players=[];
  $("app").hidden=true;$("setup").hidden=false;status(message);
}
async function restoreTabSession(){
  let saved;try{saved=JSON.parse(sessionStorage.getItem(SESSION_KEY)||"null");}catch{clearTabSession();return;}
  if(!saved?.room||!saved?.player)return;
  session={room:saved.room,player:saved.player,isHost:!!saved.isHost};
  $("roomCode").value=saved.code||"";$("nickname").value=saved.nickname||"";
  try{
    await refreshAll();
    $("setup").hidden=true;$("app").hidden=false;
    $("roomLabel").textContent=roomData.code||saved.code;
    $("playerLabel").textContent=(saved.nickname||players.find(p=>p.id===session.player)?.nickname||"玩家")+(session.isHost?"（主持人）":"");
    status("已恢復房間");switchView(["home","author","play","results"].includes(saved.view)?saved.view:"home");
  }catch(e){resetToSetup("原房間已失效，請重新加入");toast(e.message||"無法恢復房間");}
}

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const norm = (s) => String(s ?? "").trim().toLocaleLowerCase("zh-TW");
function toast(msg) { const el=$("toast"); el.textContent=msg; el.hidden=false; setTimeout(()=>el.hidden=true,3200); }
function status(msg) { $("connection").textContent=msg; }
function setBusy(v) { busy=v; document.querySelectorAll("button").forEach(b=>{if(!b.dataset.noBusy)b.disabled=v;}); }
function randomCode(){return Math.random().toString(36).slice(2,8).toUpperCase();}
function validPin(pin){return /^\d{4,8}$/.test(pin);}
function switchView(view){
  currentView=view;
  if(session.player)saveTabSession();
  document.querySelectorAll(".view").forEach(v=>v.hidden=true);
  $("view-"+view).hidden=false;
  document.querySelectorAll(".tab").forEach(b=>b.classList.toggle("active",b.dataset.view===view));
  if(session.player) refreshAll().catch(e=>toast(e.message||"載入失敗"));
}
document.querySelectorAll(".tab").forEach(b=>b.addEventListener("click",()=>switchView(b.dataset.view)));
$("configNotice").textContent = configured ? "已設定 Supabase 連線資訊，準備連線。" : "請先編輯 config.js，填入 Supabase URL 與 anon key。";
if(configured) {status("已設定連線");restoreTabSession();} else status("未設定");

async function rpc(name,args={}) {
  if(!supabase) throw new Error("尚未設定 Supabase。請先編輯 config.js。");
  // 所有登入後的 RPC 都需要帶入目前房間與參加者識別碼。
  // 這是聚餐原型的簡化識別方式，不等同正式身分驗證。
  const needsSession = !["create_room","join_room"].includes(name);
  const payload = {...args};
  if(needsSession && session.room && session.player) {
    payload.p_room_id = payload.p_room_id || session.room;
    payload.p_player_id = session.player;
  }
  const {data,error}=await supabase.rpc(name,payload);
  if(error) throw error;
  return data;
}
async function joinRoom(create=false){
  const code=$("roomCode").value.trim().toUpperCase();
  const nickname=$("nickname").value.trim();
  const pin=$("pin").value.trim();
  if(!create && !code) return toast("請輸入房間代碼。");
  if(!nickname) return toast("請輸入暱稱。");
  if(!validPin(pin)) return toast("PIN 必須是 4～8 位數字。");
  setBusy(true);
  try{
    let roomCode=code;
    if(create){
      roomCode=randomCode();
      const room=await rpc("create_room",{p_code:roomCode,p_nickname:nickname,p_pin:pin});
      session={room:room.room_id,player:room.player_id,isHost:true};
      $("roomCode").value=roomCode;
      toast("房間建立成功，請記下房間代碼："+roomCode);
    }else{
      const joined=await rpc("join_room",{p_code:roomCode,p_nickname:nickname,p_pin:pin});
      session={room:joined.room_id,player:joined.player_id,isHost:joined.is_host};
      toast("已加入房間。");
    }
    $("setup").hidden=true; $("app").hidden=false;
    $("roomLabel").textContent=roomCode;
    $("playerLabel").textContent=nickname+(session.isHost?"（主持人）":"");
    status("已連線");
    saveTabSession();
    await refreshAll();
    switchView("home");
  }catch(e){toast(e.message||"無法加入房間");}
  finally{setBusy(false);}
}
$("joinBtn").addEventListener("click",()=>joinRoom(false));
$("createBtn").addEventListener("click",()=>joinRoom(true));
$("leaveBtn").addEventListener("click",()=>resetToSetup());
$("qType").addEventListener("change",updateQuestionType);
function renderChoiceEditor(values=[] , selected="", images=[]) {
  const box=$("singleOptions"); box.innerHTML=Array.from({length:4},(_,i)=>`<div class="choice-editor"><label><input type="radio" name="qSingleCorrect" value="${i}" ${values[i]===selected && selected!==""?"checked":""}>${String.fromCharCode(65+i)}.</label><input class="q-choice-text" data-option-index="${i}" maxlength="250" placeholder="選項 ${String.fromCharCode(65+i)}" value="${esc((values[i]||"").startsWith("__FQ_IMAGE_ONLY_")?"":(values[i]||""))}"><label class="tiny">選項圖片（選填）<input class="q-option-image" data-option-image="${i}" type="file" accept="image/jpeg,image/png,image/webp"></label><span class="tiny muted">${images[i]?`<img class="q-image option-image" src="${esc(publicImageUrl(images[i]))}" alt="已儲存的選項 ${i+1} 圖片"><span>已附圖片；選擇新檔可替換</span>`:""}</span></div>`).join("");
}
function updatePointsHint(){
  const editing=$("editQuestionId").value;
  const other=myQuestions.filter(q=>q.id!==editing);
  const remaining=10-(other.length+1);
  const used=other.reduce((sum,q)=>sum+Number(q.points),0);
  const max=100-used-remaining;
  if(!editing && other.length===9) $("qPoints").value=100-used;
  $("pointsHint").textContent=`其他題已配 ${used} 分；這題可配 1～${max} 分${remaining===0?"（最後一題自動補至 100 分）":"，並為未來每題保留至少 1 分"}。`;
  $("qPoints").max=Math.max(1,max);
}
$("qPoints").addEventListener("input",updatePointsHint);
function updateQuestionType(){
  const t=$("qType").value;
  if(lastQuestionType=== "single" && t!=="single"){
    choiceDraft={values:[...document.querySelectorAll(".q-choice-text")].map(el=>el.value),
      selected:document.querySelector('input[name="qSingleCorrect"]:checked')?.value??"",
      images:[...document.querySelectorAll(".q-option-image")].map(el=>el.files?.[0]||null)};
  }
  if(["fill","short"].includes(lastQuestionType)) textAnswersByType[lastQuestionType]=$("qAnswer").value.startsWith("__FQ_IMAGE_ONLY_")?"":$("qAnswer").value;
  if(t==="single" && !$('singleOptions').children.length) renderChoiceEditor();
  if(t==="single" && choiceDraft && lastQuestionType!=="single"){
    const stored=myQuestions.find(q=>q.id===$("editQuestionId").value);
    renderChoiceEditor(choiceDraft.values,"",stored?.type==="single"?stored.option_image_paths||[]:[]);
    const checked=document.querySelector(`input[name="qSingleCorrect"][value="${choiceDraft.selected}"]`);if(checked)checked.checked=true;
    [...document.querySelectorAll(".q-option-image")].forEach((input,i)=>{
      const f=choiceDraft.images[i];if(!f)return;
      try {const dt=new DataTransfer();dt.items.add(f);input.files=dt.files;}catch{}
    });
  }
  if(["fill","short"].includes(t)) $("qAnswer").value=textAnswersByType[t]||"";
  $("optionsField").hidden=t!=="single";
  $("booleanField").hidden=t!=="boolean";
  $("answerField").hidden=t==="single"||t==="boolean";
  $("imageField").hidden=false;
  lastQuestionType=t;
  updateQuestionPreview();
}
function resetQuestionForm(){
  $("editQuestionId").value="";$("questionForm").reset();$("qType").value="single";$("qPoints").value=10;
  choiceDraft=null;textAnswersByType={fill:"",short:""};lastQuestionType="single";
  $("singleOptions").innerHTML="";renderChoiceEditor();$("currentQuestionImage").innerHTML="";
  $("saveQuestionBtn").textContent="儲存題目";$("cancelEditBtn").hidden=true;updateQuestionType();updatePointsHint();updateQuestionPreview();
}
$("cancelEditBtn").addEventListener("click",resetQuestionForm);
$("questionForm").addEventListener("submit",async e=>{
  e.preventDefault();
  if(!roomData || roomData.status!=="draft") return toast("題庫已鎖定，不能修改。");
  const type=$("qType").value, text=$("qText").value.trim();
  const existing=myQuestions.find(q=>q.id===$("editQuestionId").value);
  const optionEditors=[...document.querySelectorAll(".q-choice-text")];
  const optionHasImage=i=>Boolean(document.querySelector(`[data-option-image="${i}"]`)?.files[0] || (existing?.type==="single" && existing?.option_image_paths?.[i]));
  const options=type==="single"?optionEditors.map((x,i)=>x.value.trim() || (optionHasImage(i)?`__FQ_IMAGE_ONLY_${i}__`:"")):type==="boolean"?["是","否"]:[];
  const selected=document.querySelector('input[name="qSingleCorrect"]:checked');
  const answer=type==="single" ? (selected?options[Number(selected.value)]:"") : type==="boolean" ? (document.querySelector('input[name="qBoolean"]:checked')?.value||"") : ($("qAnswer").value.startsWith("__FQ_IMAGE_ONLY_")?"":$("qAnswer").value.trim());
  const editing=$("editQuestionId").value;
  const other=myQuestions.filter(q=>q.id!==editing);
  const used=other.reduce((v,q)=>v+Number(q.points),0);
  const remaining=10-other.length-1;
  const points=other.length===9?100-used:Number($("qPoints").value);
  if(!text && !$("qImage").files[0] && !existing?.image_path) return toast("請輸入題目文字或上傳題幹圖片。");
  if(!answer) return toast("請填寫標準答案。");
  if(!Number.isInteger(points)||points<1||points>100) return toast("配分需為 1～100 的整數。");
  if(type==="single" && (options.length!==4||options.some(o=>!o)||new Set(options).size!==4)) return toast("四個選項都必須有文字或圖片，而且文字選項不可重複。");
  if(used+points+remaining>100) return toast(`配分過高！還有 ${remaining} 題必須各保留至少 1 分。`);
  if(remaining===0 && used+points!==100) return toast("第 10 題必須補足至 100 分。");
  if(type==="boolean" && !["true","false","是","否"].includes(answer.toLowerCase())) return toast("是非題答案請填 true、false、是或否。");
  if(type==="single" && !options.includes(answer)) return toast("選擇題的答案必須完全符合其中一個選項。");
  if(myQuestions.length>=10 && !$("editQuestionId").value) return toast("每人最多建立 10 題。");
  setBusy(true);
  try{
    let imagePath=null;
    imagePath=existing?.image_path||null;
    async function uploadImage(file){
      if(!file) return null;
      if(file.size>5*1024*1024) throw new Error("圖片不可超過 5 MB。");
      if(!["image/jpeg","image/png","image/webp"].includes(file.type)) throw new Error("只接受 JPG、PNG、WebP 圖片。");
      const ext=file.type==="image/png"?"png":file.type==="image/webp"?"webp":"jpg";
      const path=`${session.room}/${session.player}/${crypto.randomUUID()}.${ext}`;
      const {error}=await supabase.storage.from("quiz-images").upload(path,file,{upsert:false,contentType:file.type});
      if(error) throw error;
      return path;
    }
    imagePath=await uploadImage($("qImage").files[0]) || imagePath;
    const optionImages=type==="single" && existing?.type==="single"?[...(existing?.option_image_paths||[])]:[];
    for(let i=0;i<4;i++){
      const file=document.querySelector(`[data-option-image="${i}"]`)?.files[0];
      if(file)optionImages[i]=await uploadImage(file);
    }
    while(optionImages.length<4) optionImages.push(null);
    const payload={p_question_id:existing?.id||null,p_type:type,p_text:text,p_options:options,p_correct_answer:answer,p_explanation:$("qExplanation").value.trim(),p_points:points,p_image_path:imagePath,p_option_images:type==="single"?optionImages:[]};
    await rpc("save_question",payload);
    resetQuestionForm();await refreshAll();toast("題目已儲存。");
  }catch(err){toast(err.message||"儲存題目失敗");}
  finally{setBusy(false);}
});

async function refreshAll(){
  if(!session.room) return;
  const [room,people,own,questions,submits]=await Promise.all([
    rpc("get_room_state",{p_room_id:session.room}),
    rpc("list_players",{p_room_id:session.room}),
    rpc("my_questions",{p_room_id:session.room}),
    rpc("list_questions",{p_room_id:session.room}),
    rpc("submission_status",{p_room_id:session.room})
  ]);
  roomData=room;players=people||[];myQuestions=own||[];allQuestions=(questions||[]).map(q=>({...q,option_image_urls:(q.option_image_paths||[]).map(publicImageUrl),image_url:q.image_path?`${cfg.SUPABASE_URL}/storage/v1/object/public/quiz-images/${q.image_path}`:null}));answers=submits||[];
  session.isHost=!!room.is_host;
  renderHome();renderMyQuestions();renderPlay();renderResults();
}
function renderHome(){
  $("memberCount").textContent=players.length;
  $("questionCount").textContent=allQuestions.length;
  $("submittedCount").textContent=answers.filter(a=>a.submitted).length;
  const labels={draft:"出題中：大家可以新增或修改題目。",locked:"題庫已鎖定：可以開始作答。",revealed:"答案已公布：正在閱卷／查看結果。"};
  $("roomState").textContent=labels[roomData.status]||"房間狀態未知。";
  $("hostControls").hidden=!session.isHost;
  $("lockBtn").hidden=!session.isHost||roomData.status!=="draft";
  $("revealBtn").hidden=!session.isHost||roomData.status!=="locked";
  $("membersList").innerHTML=players.map(p=>`<li class="member-row"><span>${esc(p.nickname)}${p.is_host?' <strong>· 主持人</strong>':''}${p.question_count!==undefined?`<br><span class="muted tiny">已出題 ${p.question_count}/10</span>`:''}${p.submitted?' <span class="tiny">· 已交卷</span>':''}</span>${session.isHost && !p.is_host && roomData.status==="draft"?`<button type="button" class="small danger" data-kick="${esc(p.id)}">剔除</button>`:""}</li>`).join("");
  $("membersList").querySelectorAll("[data-kick]").forEach(b=>b.addEventListener("click",async()=>{
    const target=players.find(p=>p.id===b.dataset.kick);
    if(!target||!confirm(`確定剔除 ${target.nickname}？對方的題目也會刪除，且只有在出題階段可以剔除。`))return;
    try{await rpc("kick_player",{p_target_player_id:target.id});await refreshAll();toast("已剔除參加者");}catch(e){toast(e.message||"無法剔除");}
  }));
}
function renderMyQuestions(){
  $("myQuestionCount").textContent=`${myQuestions.length} / 10（${myQuestions.reduce((sum,q)=>sum+Number(q.points),0)} 分）`;
  updatePointsHint();
  $("authorLocked").hidden=roomData.status==="draft";
  $("questionForm").hidden=roomData.status!=="draft";
  $("myQuestions").innerHTML=myQuestions.map((q,i)=>`<article class="q-card">
    <div class="q-top"><span class="q-number">第 ${i+1} 題</span><span class="q-meta">${typeName(q.type)} · ${q.points} 分</span></div>
    <div class="q-title">${esc(q.question_text)}</div>
    ${q.image_path?`<div class="muted tiny">已附圖片</div>`:""}
    <div class="q-actions"><button class="secondary" data-edit="${q.id}">編輯</button><button class="danger" data-delete="${q.id}">刪除</button></div>
  </article>`).join("")||'<p class="muted">尚未建立題目。</p>';
  $("myQuestions").querySelectorAll("[data-edit]").forEach(b=>b.addEventListener("click",()=>editQuestion(b.dataset.edit)));
  $("myQuestions").querySelectorAll("[data-delete]").forEach(b=>b.addEventListener("click",()=>deleteQuestion(b.dataset.delete)));
}
function typeName(t){return ({single:"選擇題",boolean:"是非題",fill:"填空題",short:"簡答題"})[t]||t;}
function publicImageUrl(path){return path?`${cfg.SUPABASE_URL}/storage/v1/object/public/quiz-images/${path}`:null;}
function editQuestion(id){
  const q=myQuestions.find(x=>x.id===id);if(!q)return;
  $("editQuestionId").value=q.id;$("qType").value=q.type;$("qText").value=q.question_text;
  $("qImage").value="";choiceDraft=null;textAnswersByType={fill:"",short:""};lastQuestionType=q.type;
  if(q.type==="fill"||q.type==="short")textAnswersByType[q.type]=q.correct_answer?.startsWith("__FQ_IMAGE_ONLY_")?"":q.correct_answer||"";
  $("qOptions").value=(q.options||[]).join("\n");$("qAnswer").value=q.correct_answer?.startsWith("__FQ_IMAGE_ONLY_")?"":q.correct_answer||"";
  renderChoiceEditor(q.type==="single"?(q.options||[]):[],q.type==="single"?q.correct_answer:"",q.type==="single"?q.option_image_paths||[]:[]);
  $("currentQuestionImage").innerHTML=q.image_path?`<img class="q-image" src="${esc(publicImageUrl(q.image_path))}" alt="已儲存的題幹圖片"><span>已附題幹圖片；選擇新檔可替換</span>`:"";
  if(q.type==="boolean") {const radio=document.querySelector(`input[name="qBoolean"][value="${q.correct_answer}"]`);if(radio)radio.checked=true;}
  $("qExplanation").value=q.explanation||"";$("qPoints").value=q.points;
  $("saveQuestionBtn").textContent="更新題目";$("cancelEditBtn").hidden=false;updateQuestionType();updatePointsHint();updateQuestionPreview();
  window.scrollTo({top:$("questionForm").getBoundingClientRect().top+window.scrollY-20,behavior:"smooth"});
}
async function deleteQuestion(id){
  if(!confirm("確定刪除這道題目？"))return;
  try{await rpc("delete_question",{p_question_id:id});await refreshAll();toast("已刪除。");}catch(e){toast(e.message);}
}
$("lockBtn").addEventListener("click",async()=>{
  if(!confirm("鎖定後所有人不能再修改題目。確定繼續？"))return;
  try{await rpc("lock_room",{p_room_id:session.room});await refreshAll();toast("題庫已鎖定。");}catch(e){toast(e.message);}
});
$("revealBtn").addEventListener("click",async()=>{
  const pending=answers.filter(a=>!a.submitted).length;
  if(pending && !confirm(`還有 ${pending} 位參加者尚未交卷。仍要公布答案嗎？`))return;
  if(!confirm("公布答案後無法撤回，確定公布？"))return;
  try{await rpc("reveal_answers",{p_room_id:session.room});await refreshAll();toast("答案已公布。");}catch(e){toast(e.message);}
});

function renderPlay(){
  const ready=roomData.status==="locked", revealed=roomData.status==="revealed";
  const mine=answers.find(a=>a.player_id===session.player);const alreadySubmitted=!!mine?.submitted;
  $("playNotice").textContent=ready?"請回答所有題目後再交卷。":revealed?"答案已公布，作答已結束。": "主持人鎖定題庫並開放作答後，即可開始。";
  $("submitAnswersBtn").hidden=!ready||alreadySubmitted;
  const saved={...(mine?.responses||{}),...answerDraft};
  const playable=allQuestions;
  $("playProgress").textContent=`${Object.values(saved).filter(v=>String(v||"").trim()).length} / ${playable.length}`;
  $("playQuestions").innerHTML=ready?allQuestions.map((q,i)=>renderPlayQuestion(q,i,saved[q.id])).join(""):'';
  $("playQuestions").querySelectorAll("input,textarea").forEach(el=>el.addEventListener("input",()=>saveDraftAnswer(el)));
  $("submitAnswersBtn").onclick=submitAnswers;
}
function renderPlayQuestion(q,i,answer){
  const opts=q.options||[];
  let input="";
  if(q.type==="single"||q.type==="boolean"){
    input=`<div class="q-options">${opts.map((o,j)=>`<label class="option"><input type="radio" name="answer-${q.id}" value="${esc(o)}" ${answer===o?'checked':''}><span>${esc(o.startsWith("__FQ_IMAGE_ONLY_")?"":o)}${q.option_image_urls?.[j]?`<img class="q-image option-image" src="${esc(q.option_image_urls[j])}" alt="選項 ${j+1} 圖片">`:""}</span></label>`).join("")}</div>`;
  }else if(q.type==="fill"){
    input=`<div class="field"><label>你的答案</label><input data-answer-for="${q.id}" value="${esc(answer||"")}" maxlength="1000" placeholder="輸入答案"></div>`;
  }else{
    input=`<div class="field"><label>你的答案</label><textarea data-answer-for="${q.id}" rows="3" maxlength="2000" placeholder="請寫下你的回答">${esc(answer||"")}</textarea></div>`;
  }
  const image=q.image_url?`<img class="q-image" src="${esc(q.image_url)}" alt="題目圖片">`:"";
  return `<article class="q-card" data-qcard="${q.id}"><div class="q-top"><span class="q-number">第 ${i+1} 題</span><span class="q-meta">${typeName(q.type)} · ${q.points} 分</span></div><div class="q-title">${esc(q.question_text)}</div>${image}${input}</article>`;
}
function saveDraftAnswer(el){
  const qid=el.dataset.answerFor || el.name?.replace("answer-","");
  if(!qid)return;
  const card=document.querySelector(`[data-qcard="${qid}"]`);
  if(el.type==="radio"){const chosen=card.querySelector("input[type=radio]:checked");answerDraft[qid]=chosen?.value??null;}
  else answerDraft[qid]=el.value;
  $("playProgress").textContent=`${allQuestions.filter(q=>String(answerDraft[q.id]||"").trim()).length} / ${allQuestions.length}`;
}
async function submitAnswers(){
  if(!confirm("交卷後不能修改答案，確定交卷？"))return;
  const responses={};
  for(const q of allQuestions){
    const card=document.querySelector(`[data-qcard="${q.id}"]`);
    if(!card)continue;
    if(q.type==="single"||q.type==="boolean")responses[q.id]=card.querySelector("input[type=radio]:checked")?.value??"";
    else responses[q.id]=card.querySelector("[data-answer-for]")?.value?.trim()??"";
  }
  if(Object.values(responses).some(v=>v===""))return toast("還有題目未作答，請完成所有題目。");
  try{await rpc("submit_answers",{p_room_id:session.room,p_responses:responses});await refreshAll();toast("交卷成功！等主持人統一公布答案。");}catch(e){toast(e.message||"交卷失敗");}
}

function renderResults(){
  const revealed=roomData.status==="revealed";
  $("resultsNotice").textContent=revealed?"答案已公布。由每題原出題者批改簡答題（顯示作答者）；選擇、是非與填空題自動評分。":"所有人交卷後，由主持人公布答案。";
  $("gradingArea").innerHTML="";$("leaderboard").innerHTML="";$("answerReview").innerHTML="";
  if(!revealed)return;
  if(gradingQueue.length){
    $("gradingArea").innerHTML=`<h3>我出的簡答題・人工閱卷</h3><p class="muted tiny">僅批改其他玩家對我所出題目的答案。</p><div id="manualGrades" class="question-list"></div><button id="saveGradesBtn" class="primary wide">儲存我的評分</button>`;
    $("manualGrades").innerHTML=gradingQueue.map((g,i)=>`<article class="q-card"><div class="q-top"><span class="q-number">${esc(g.question_text)}</span><span class="q-meta">滿分 ${g.max_points}</span></div><p><strong>${esc(g.nickname||"未知玩家")}：</strong>${esc(g.response)}</p><p class="muted tiny">參考答案：${esc(g.correct_answer)}</p><label>給分（0～${g.max_points}）</label><input type="number" min="0" max="${g.max_points}" step="1" data-grade-token="${esc(g.token)}" value="${g.awarded_points??""}"></article>`).join("");
    $("saveGradesBtn").onclick=saveGrades;
  }
  const board=[...results].sort((a,b)=>Number(b.total)-Number(a.total));
  $("leaderboard").innerHTML=`<h3>排行榜</h3>${board.map((p,i)=>`<div class="score-row"><span><span class="q-number">#${i+1}</span> <span class="score-name">${esc(p.nickname)}</span>${p.pending?' <span class="tiny muted">（有題目待評分）</span>':''}</span><span class="score-value">${p.total} / ${p.max} 分</span></div>`).join("")||'<p class="muted">尚無成績。</p>'}`;
  $("answerReview").innerHTML=allQuestions.map((q,i)=>`<article class="q-card"><div class="q-top"><span class="q-number">第 ${i+1} 題</span><span class="q-meta">${typeName(q.type)} · ${q.points} 分</span></div><div class="q-title">${esc(q.question_text)}</div>${q.image_url?`<img class="q-image" src="${esc(q.image_url)}" alt="題目圖片">`:""}${(q.option_image_urls||[]).map((u,j)=>u?`<div class="tiny">選項 ${j+1}<img class="q-image option-image" src="${esc(u)}" alt="選項圖片"></div>`:"").join("")}<div class="q-answer"><strong>標準／參考答案：</strong>${esc(q.correct_answer?.startsWith("__FQ_IMAGE_ONLY_")?"圖片選項 "+String.fromCharCode(65+Number(q.correct_answer.match(/\d+/)?.[0]||0)):q.correct_answer||"（待人工評分）")}<br>${q.explanation?`<strong>解析：</strong>${esc(q.explanation)}<br>`:""}<strong>出題者：</strong>${esc(q.author_nickname||"未知")}</div></article>`).join("");
}
async function saveGrades(){
  const items=[];
  for(const el of document.querySelectorAll("[data-grade-token]")){
    if(el.value==="")continue;
    const points=Number(el.value);
    if(!Number.isInteger(points)||points<0||points>Number(el.max))return toast("分數必須是 0 到滿分的整數。");
    items.push({token:el.dataset.gradeToken,points});
  }
  try {await rpc("save_anonymous_grades",{p_room_id:session.room,p_grades:items});await refreshAll();toast("人工評分已儲存。");}catch(e){toast(e.message||"儲存失敗");}
}

async function loadResults(){
  if(roomData?.status==="revealed"){
    results=await rpc("get_results",{p_room_id:session.room});
    gradingQueue=await rpc("get_grading_queue",{p_room_id:session.room});
    const reviewed=await rpc("list_questions",{p_room_id:session.room,p_include_answers:true});
    allQuestions=(reviewed||allQuestions).map(q=>({...q,option_image_urls:(q.option_image_paths||[]).map(publicImageUrl),image_url:q.image_path?`${cfg.SUPABASE_URL}/storage/v1/object/public/quiz-images/${q.image_path}`:null}));
  }else {results=[];gradingQueue=[];}
}
const originalRefresh=refreshAll;
refreshAll=async function(){
  await originalRefresh();
  await loadResults();
  renderResults();
};

// 出題介面啟動時就依預設選擇題建立四個選項，而不是等使用者切換題型。
let previewImageUrls=[];
function updateQuestionPreview(){
  const box=$("questionPreview");if(!box)return;
  previewImageUrls.forEach(url=>URL.revokeObjectURL(url));previewImageUrls=[];
  const img=(fileInput,existingPath,alt)=>{
    const file=fileInput?.files?.[0];let url=file?URL.createObjectURL(file):publicImageUrl(existingPath);
    if(file)previewImageUrls.push(url);
    return url?`<img class="q-image" src="${esc(url)}" alt="${esc(alt)}">`:"";
  };
  const t=$("qType").value;
  const existing=myQuestions.find(q=>q.id===$("editQuestionId").value);
  const title=esc($("qText").value.trim()||"（請輸入題目內容）");
  let inputs="";
  if(t==="single"){
    inputs='<div class="q-options">'+[...document.querySelectorAll(".q-choice-text")].map((el,i)=>{
      const checked=document.querySelector('input[name="qSingleCorrect"]:checked')?.value===String(i);
      return `<label class="option"><input type="radio" disabled ${checked?"checked":""}><span>${esc(el.value.trim())}${img(document.querySelector(`[data-option-image="${i}"]`),existing?.option_image_paths?.[i],"選項圖片")}</span></label>`;
    }).join("")+"</div>";
  }else if(t==="boolean")inputs=`<div class="q-options"><label class="option"><input type="radio" disabled> 是</label><label class="option"><input type="radio" disabled> 否</label></div>`;
  else inputs='<input placeholder="作答時在這裡輸入答案" disabled>';
  box.innerHTML=`<article class="q-card"><div class="q-top"><span class="q-number">題目預覽</span><span class="q-meta">${typeName(t)} · ${esc($("qPoints").value||10)} 分</span></div><div class="q-title">${title}</div>${img($("qImage"),existing?.image_path,"題幹圖片")}${inputs}</article>`;
}
$("questionForm").addEventListener("input",updateQuestionPreview);
$("questionForm").addEventListener("change",updateQuestionPreview);
$("previewQuestionBtn").addEventListener("click",()=>{
  updateQuestionPreview();$("questionPreview").hidden=false;
  $("questionPreview").scrollIntoView({behavior:"smooth",block:"nearest"});
});
updateQuestionPreview();
resetQuestionForm();
