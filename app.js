import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm";

const cfg = window.QUIZ_CONFIG || {};
const configured = cfg.SUPABASE_URL && cfg.SUPABASE_ANON_KEY &&
  !cfg.SUPABASE_URL.includes("YOUR-PROJECT") && !cfg.SUPABASE_ANON_KEY.includes("YOUR_SUPABASE");
const $ = (id) => document.getElementById(id);
const supabase = configured ? createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY) : null;
let session = { room: null, player: null, isHost: false };
let roomData = null, players = [], myQuestions = [], allQuestions = [], answers = [], results = [];
let currentView = "home", busy = false;

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const norm = (s) => String(s ?? "").trim().toLocaleLowerCase("zh-TW");
function toast(msg) { const el=$("toast"); el.textContent=msg; el.hidden=false; setTimeout(()=>el.hidden=true,3200); }
function status(msg) { $("connection").textContent=msg; }
function setBusy(v) { busy=v; document.querySelectorAll("button").forEach(b=>{if(!b.dataset.noBusy)b.disabled=v;}); }
function randomCode(){return Math.random().toString(36).slice(2,8).toUpperCase();}
function validPin(pin){return /^\d{4,8}$/.test(pin);}
function switchView(view){
  currentView=view;
  document.querySelectorAll(".view").forEach(v=>v.hidden=true);
  $("view-"+view).hidden=false;
  document.querySelectorAll(".tab").forEach(b=>b.classList.toggle("active",b.dataset.view===view));
  if(session.player) refreshAll().catch(e=>toast(e.message||"載入失敗"));
}
document.querySelectorAll(".tab").forEach(b=>b.addEventListener("click",()=>switchView(b.dataset.view)));
$("configNotice").textContent = configured ? "已設定 Supabase 連線資訊，準備連線。" : "請先編輯 config.js，填入 Supabase URL 與 anon key。";
if(configured) status("已設定連線"); else status("未設定");

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
    await refreshAll();
    switchView("home");
  }catch(e){toast(e.message||"無法加入房間");}
  finally{setBusy(false);}
}
$("joinBtn").addEventListener("click",()=>joinRoom(false));
$("createBtn").addEventListener("click",()=>joinRoom(true));
$("leaveBtn").addEventListener("click",()=>{session={room:null,player:null,isHost:false};$("app").hidden=true;$("setup").hidden=false;status("已離開");});
$("qType").addEventListener("change",updateQuestionType);
function updateQuestionType(){
  const t=$("qType").value;
  $("optionsField").hidden=!(t==="single"||t==="boolean"||t==="image");
  $("imageField").hidden=t!=="image";
  if(t==="boolean") $("qOptions").value="是\n否";
  else if(t==="single" && $("qOptions").value==="是\n否") $("qOptions").value="";
}
function resetQuestionForm(){
  $("editQuestionId").value="";$("questionForm").reset();$("qPoints").value=1;
  $("saveQuestionBtn").textContent="儲存題目";$("cancelEditBtn").hidden=true;updateQuestionType();
}
$("cancelEditBtn").addEventListener("click",resetQuestionForm);
$("questionForm").addEventListener("submit",async e=>{
  e.preventDefault();
  if(!roomData || roomData.status!=="draft") return toast("題庫已鎖定，不能修改。");
  const type=$("qType").value, text=$("qText").value.trim(), answer=$("qAnswer").value.trim();
  const options=$("qOptions").value.split("\n").map(x=>x.trim()).filter(Boolean);
  const points=Number($("qPoints").value);
  if(!text) return toast("請輸入題目。");
  if(!answer) return toast("請填寫標準答案。");
  if(!Number.isInteger(points)||points<1||points>100) return toast("配分需為 1～100 的整數。");
  if(type==="single" && (options.length<2||options.length>6)) return toast("選擇題需有 2～6 個選項。");
  if(type==="boolean" && !["true","false","是","否"].includes(answer.toLowerCase())) return toast("是非題答案請填 true、false、是或否。");
  if(type==="image" && !$("qImage").files[0] && !$("editQuestionId").value) return toast("圖片題請選擇一張圖片。");
  if(type==="single" && !options.includes(answer)) return toast("選擇題的答案必須完全符合其中一個選項。");
  if(myQuestions.length>=10 && !$("editQuestionId").value) return toast("每人最多建立 10 題。");
  setBusy(true);
  try{
    let imagePath=null;
    const existing=myQuestions.find(q=>q.id===$("editQuestionId").value);
    imagePath=existing?.image_path||null;
    const file=$("qImage").files[0];
    if(file){
      if(file.size>5*1024*1024) throw new Error("圖片不可超過 5 MB。");
      if(!["image/jpeg","image/png","image/webp"].includes(file.type)) throw new Error("只接受 JPG、PNG、WebP 圖片。");
      const ext=file.type==="image/png"?"png":file.type==="image/webp"?"webp":"jpg";
      imagePath=`${session.room}/${session.player}/${crypto.randomUUID()}.${ext}`;
      const {error}=await supabase.storage.from("quiz-images").upload(imagePath,file,{upsert:false,contentType:file.type});
      if(error) throw error;
    }
    const payload={p_question_id:existing?.id||null,p_type:type,p_text:text,p_options:options,p_correct_answer:answer,p_explanation:$("qExplanation").value.trim(),p_points:points,p_image_path:imagePath};
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
  roomData=room;players=people||[];myQuestions=own||[];allQuestions=questions||[];answers=submits||[];
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
  $("membersList").innerHTML=players.map(p=>`<li>${esc(p.nickname)}${p.is_host?' <strong>· 主持人</strong>':''}${p.question_count!==undefined?`<br><span class="muted tiny">已出題 ${p.question_count}/10</span>`:''}${p.submitted?' <span class="tiny">· 已交卷</span>':''}</li>`).join("");
}
function renderMyQuestions(){
  $("myQuestionCount").textContent=`${myQuestions.length} / 10`;
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
function typeName(t){return ({single:"選擇題",boolean:"是非題",fill:"填空題",short:"簡答題",image:"圖片題"})[t]||t;}
function editQuestion(id){
  const q=myQuestions.find(x=>x.id===id);if(!q)return;
  $("editQuestionId").value=q.id;$("qType").value=q.type;$("qText").value=q.question_text;
  $("qOptions").value=(q.options||[]).join("\n");$("qAnswer").value=q.correct_answer;
  $("qExplanation").value=q.explanation||"";$("qPoints").value=q.points;
  $("saveQuestionBtn").textContent="更新題目";$("cancelEditBtn").hidden=false;updateQuestionType();
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
  $("playNotice").textContent=ready?"請回答所有題目後再交卷。":revealed?"答案已公布，作答已結束。": "主持人鎖定題庫並開放作答後，即可開始。";
  $("submitAnswersBtn").hidden=!ready||answers.some(a=>a.player_id===session.player&&a.submitted);
  const mine=answers.find(a=>a.player_id===session.player);
  const saved=mine?.responses||{};
  $("playProgress").textContent=`${Object.keys(saved).length} / ${allQuestions.length}`;
  $("playQuestions").innerHTML=ready?allQuestions.map((q,i)=>renderPlayQuestion(q,i,saved[q.id])).join(""):'';
  $("playQuestions").querySelectorAll("input,textarea").forEach(el=>el.addEventListener("change",()=>saveDraftAnswer(el)));
  $("submitAnswersBtn").onclick=submitAnswers;
}
function renderPlayQuestion(q,i,answer){
  const opts=q.options||[];
  let input="";
  if(q.type==="single"||q.type==="boolean"||q.type==="image"){
    input=`<div class="q-options">${opts.map((o,j)=>`<label class="option"><input type="radio" name="answer-${q.id}" value="${esc(o)}" ${answer===o?'checked':''}><span>${esc(o)}</span></label>`).join("")}</div>`;
  }else if(q.type==="fill"){
    input=`<div class="field"><label>你的答案</label><input data-answer-for="${q.id}" value="${esc(answer||"")}" maxlength="1000" placeholder="輸入答案"></div>`;
  }else{
    input=`<div class="field"><label>你的答案</label><textarea data-answer-for="${q.id}" rows="3" maxlength="2000" placeholder="請寫下你的回答">${esc(answer||"")}</textarea></div>`;
  }
  const image=q.image_url?`<img class="q-image" src="${esc(q.image_url)}" alt="題目圖片">`:"";
  return `<article class="q-card" data-qcard="${q.id}"><div class="q-top"><span class="q-number">第 ${i+1} 題</span><span class="q-meta">${typeName(q.type)} · ${q.points} 分</span></div><div class="q-title">${esc(q.question_text)}</div>${image}${input}</article>`;
}
let answerDraft={};
function saveDraftAnswer(el){
  const qid=el.dataset.answerFor || el.name?.replace("answer-","");
  if(!qid)return;
  const card=document.querySelector(`[data-qcard="${qid}"]`);
  if(el.type==="radio"){const chosen=card.querySelector("input[type=radio]:checked");answerDraft[qid]=chosen?.value??null;}
  else answerDraft[qid]=el.value;
}
async function submitAnswers(){
  if(!confirm("交卷後不能修改答案，確定交卷？"))return;
  const responses={};
  for(const q of allQuestions){
    const card=document.querySelector(`[data-qcard="${q.id}"]`);
    if(!card)continue;
    if(q.type==="single"||q.type==="boolean"||q.type==="image")responses[q.id]=card.querySelector("input[type=radio]:checked")?.value??"";
    else responses[q.id]=card.querySelector("[data-answer-for]")?.value?.trim()??"";
  }
  if(Object.values(responses).some(v=>v===""))return toast("還有題目未作答，請完成所有題目。");
  try{await rpc("submit_answers",{p_room_id:session.room,p_responses:responses});await refreshAll();toast("交卷成功！等主持人統一公布答案。");}catch(e){toast(e.message||"交卷失敗");}
}

function renderResults(){
  const revealed=roomData.status==="revealed";
  $("resultsNotice").textContent=revealed?"答案已公布。簡答題需要主持人評分；其他題型由系統批改。": "所有人交卷後，由主持人公布答案。";
  $("gradingArea").innerHTML="";
  $("leaderboard").innerHTML="";
  $("answerReview").innerHTML="";
  if(!revealed)return;
  const grades=results;
  if(session.isHost){
    $("gradingArea").innerHTML=`<h3>簡答題人工評分</h3><div id="manualGrades" class="question-list"></div><button id="saveGradesBtn" class="primary wide">儲存人工評分並更新排名</button>`;
    const shorts=allQuestions.filter(q=>q.type==="short");
    $("manualGrades").innerHTML=shorts.map(q=>{
      const submissions=answers.filter(a=>a.submitted);
      return submissions.map(a=>{
        const resp=a.responses?.[q.id]||"";
        const current=grades.find(g=>g.player_id===a.player_id&&g.question_id===q.id)?.awarded_points??"";
        return `<article class="q-card"><div class="q-top"><span class="q-number">${esc(q.question_text)}</span><span class="q-meta">${q.points} 分滿分</span></div><p><strong>${esc(a.nickname||"參加者")}</strong>：${esc(resp)}</p><label>給分（0～${q.points}）</label><input type="number" min="0" max="${q.points}" step="1" data-grade-q="${q.id}" data-grade-p="${a.player_id}" value="${current}"></article>`;
      }).join("");
    }).join("")||'<p class="muted">沒有簡答題需要人工評分。</p>';
    $("saveGradesBtn").onclick=saveGrades;
  }
  const leaderboard=grades.reduce((acc,g)=>{let row=acc.find(x=>x.player_id===g.player_id);if(!row){row={player_id:g.player_id,nickname:g.nickname,total:0,max:0,pending:false};acc.push(row);}row.total+=Number(g.awarded_points||0);row.max+=Number(g.max_points||0);row.pending=row.pending||g.pending_manual;return acc;},[]);
  leaderboard.sort((a,b)=>b.total-a.total);
  $("leaderboard").innerHTML=`<h3>排行榜</h3>${leaderboard.map((p,i)=>`<div class="score-row"><span><span class="q-number">#${i+1}</span> <span class="score-name">${esc(p.nickname)}</span>${p.pending?' <span class="tiny muted">（簡答待評）</span>':''}</span><span class="score-value">${p.total} / ${p.max} 分</span></div>`).join("")||'<p class="muted">尚無成績。</p>'}`;
  $("answerReview").innerHTML=allQuestions.map((q,i)=>`<article class="q-card"><div class="q-top"><span class="q-number">第 ${i+1} 題</span><span class="q-meta">${typeName(q.type)} · ${q.points} 分</span></div><div class="q-title">${esc(q.question_text)}</div>${q.image_url?`<img class="q-image" src="${esc(q.image_url)}" alt="題目圖片">`:""}<div class="q-answer"><strong>正確答案：</strong>${esc(q.correct_answer||"（待人工評分）")}<br>${q.explanation?`<strong>解析：</strong>${esc(q.explanation)}<br>`:""}<strong>出題者：</strong>${esc(q.author_nickname||"未知")}</div></article>`).join("");
}
async function saveGrades(){
  const fields=[...document.querySelectorAll("[data-grade-q]")];
  const gradesToSave=[];
  for(const f of fields){
    if(f.value==="")continue;
    const n=Number(f.value),max=Number(f.max);
    if(!Number.isInteger(n)||n<0||n>max)return toast("請檢查人工評分，分數需為整數且不可超過滿分。");
    gradesToSave.push({question_id:f.dataset.gradeQ,player_id:f.dataset.gradeP,points:n});
  }
  try{await rpc("save_manual_grades",{p_room_id:session.room,p_grades:gradesToSave});await refreshAll();toast("評分已儲存。");}catch(e){toast(e.message||"儲存失敗");}
}

async function loadResults(){
  if(roomData?.status==="revealed"){
    results=await rpc("get_results",{p_room_id:session.room});
    const reviewed=await rpc("list_questions",{p_room_id:session.room,p_include_answers:true});
    allQuestions=reviewed||allQuestions;
  }else results=[];
}
const originalRefresh=refreshAll;
refreshAll=async function(){
  await originalRefresh();
  await loadResults();
  renderResults();
};
