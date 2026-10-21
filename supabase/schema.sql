-- 朋友出題大會 v1
-- 在 Supabase Dashboard > SQL Editor 以專案管理員執行。
-- 注意：這是活動用原型。PIN 以 pgcrypto 雜湊儲存；不要把 service_role key 放進前端。

create extension if not exists pgcrypto;

do $$ begin
  create type public.quiz_room_status as enum ('draft','locked','revealed');
exception when duplicate_object then null; end $$;

create table if not exists public.quiz_rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[A-Z0-9]{4,12}$'),
  status public.quiz_room_status not null default 'draft',
  created_at timestamptz not null default now(),
  revealed_at timestamptz
);

create table if not exists public.quiz_players (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.quiz_rooms(id) on delete cascade,
  nickname text not null check (char_length(nickname) between 1 and 24),
  pin_hash text not null,
  is_host boolean not null default false,
  created_at timestamptz not null default now(),
  unique(room_id, nickname),
  unique(room_id, id)
);

create table if not exists public.quiz_questions (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.quiz_rooms(id) on delete cascade,
  author_id uuid not null references public.quiz_players(id) on delete cascade,
  type text not null check (type in ('single','boolean','fill','short','image')),
  question_text text not null check (char_length(question_text) between 1 and 1200),
  options jsonb not null default '[]'::jsonb,
  correct_answer text not null,
  explanation text not null default '',
  points integer not null default 1 check (points between 1 and 100),
  image_path text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(room_id, id)
);

create table if not exists public.quiz_submissions (
  room_id uuid not null,
  player_id uuid not null,
  responses jsonb not null default '{}'::jsonb,
  submitted boolean not null default false,
  submitted_at timestamptz,
  primary key(room_id, player_id),
  foreign key(room_id, player_id) references public.quiz_players(room_id,id) on delete cascade
);

create table if not exists public.quiz_manual_grades (
  room_id uuid not null,
  player_id uuid not null,
  question_id uuid not null,
  awarded_points integer not null check (awarded_points >= 0),
  grader_id uuid not null references public.quiz_players(id),
  updated_at timestamptz not null default now(),
  primary key(room_id, player_id, question_id),
  foreign key(room_id, player_id) references public.quiz_players(room_id,id) on delete cascade,
  foreign key(room_id, question_id) references public.quiz_questions(room_id,id) on delete cascade
);

create index if not exists quiz_players_room_idx on public.quiz_players(room_id);
create index if not exists quiz_questions_room_idx on public.quiz_questions(room_id);
create index if not exists quiz_submissions_room_idx on public.quiz_submissions(room_id);

-- Do not allow direct table reads/writes from anon clients. All app access goes through RPC functions below.
alter table public.quiz_rooms enable row level security;
alter table public.quiz_players enable row level security;
alter table public.quiz_questions enable row level security;
alter table public.quiz_submissions enable row level security;
alter table public.quiz_manual_grades enable row level security;

revoke all on public.quiz_rooms, public.quiz_players, public.quiz_questions,
  public.quiz_submissions, public.quiz_manual_grades from anon, authenticated;
grant usage on schema public to anon, authenticated;

-- Helpers: RPC functions are SECURITY DEFINER but validate room/player membership and role.
create or replace function public._player_for_pin(p_room uuid, p_nickname text, p_pin text)
returns public.quiz_players language sql security definer set search_path=public,pg_temp as $$
  select p from public.quiz_players p
  where p.room_id=p_room and lower(p.nickname)=lower(trim(p_nickname))
    and p.pin_hash=crypt(p_pin,p.pin_hash) limit 1
$$;

create or replace function public.create_room(p_code text, p_nickname text, p_pin text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare r public.quiz_rooms; p public.quiz_players;
begin
  if p_code !~ '^[A-Z0-9]{4,12}$' or char_length(trim(p_nickname)) not between 1 and 24
     or p_pin !~ '^[0-9]{4,8}$' then raise exception '房間代碼、暱稱或 PIN 格式錯誤'; end if;
  insert into public.quiz_rooms(code) values (upper(p_code)) returning * into r;
  insert into public.quiz_players(room_id,nickname,pin_hash,is_host)
    values(r.id,trim(p_nickname),crypt(p_pin,gen_salt('bf')),true) returning * into p;
  return jsonb_build_object('room_id',r.id,'player_id',p.id,'room_code',r.code,'is_host',true);
end $$;

create or replace function public.join_room(p_code text, p_nickname text, p_pin text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare r public.quiz_rooms; p public.quiz_players;
begin
  select * into r from public.quiz_rooms where code=upper(trim(p_code));
  if not found then raise exception '找不到這個房間'; end if;
  if char_length(trim(p_nickname)) not between 1 and 24 or p_pin !~ '^[0-9]{4,8}$' then
    raise exception '暱稱或 PIN 格式錯誤'; end if;
  select * into p from public.quiz_players where room_id=r.id and lower(nickname)=lower(trim(p_nickname));
  if found then
    if p.pin_hash<>crypt(p_pin,p.pin_hash) then raise exception '這個暱稱已被使用，PIN 不正確'; end if;
  else
    if r.status<>'draft' then raise exception '題庫已鎖定，不能加入新參加者'; end if;
    insert into public.quiz_players(room_id,nickname,pin_hash)
      values(r.id,trim(p_nickname),crypt(p_pin,gen_salt('bf'))) returning * into p;
  end if;
  return jsonb_build_object('room_id',r.id,'player_id',p.id,'room_code',r.code,'is_host',p.is_host);
end $$;

create or replace function public._assert_member(p_room_id uuid, p_player_id uuid)
returns public.quiz_players language plpgsql security definer set search_path=public,pg_temp as $$
declare p public.quiz_players;
begin
  select * into p from public.quiz_players where id=p_player_id and room_id=p_room_id;
  if not found then raise exception '參加者驗證失敗'; end if;
  return p;
end $$;

-- The browser stores the player id only for session convenience; all RPCs validate that the id belongs to the room.
-- This is a lightweight party-game PIN model, not high-assurance identity authentication.
create or replace function public.get_room_state(p_room_id uuid, p_player_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare r public.quiz_rooms; p public.quiz_players; qcount int; submitted_count int;
begin
  select * into r from public.quiz_rooms where id=p_room_id;
  if not found then raise exception '找不到房間'; end if;
  if p_player_id is null then raise exception '缺少參加者驗證'; end if;
  p:=public._assert_member(p_room_id,p_player_id);
  select count(*) into qcount from public.quiz_questions where room_id=p_room_id;
  select count(*) into submitted_count from public.quiz_submissions where room_id=p_room_id and submitted;
  return jsonb_build_object('id',r.id,'code',r.code,'status',r.status,'is_host',p.is_host,
    'question_count',qcount,'submitted_count',submitted_count);
end $$;

create or replace function public.list_players(p_room_id uuid, p_player_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
begin
  perform public._assert_member(p_room_id,p_player_id);
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id',p.id,'nickname',p.nickname,'is_host',p.is_host,
    'question_count',(select count(*) from public.quiz_questions q where q.author_id=p.id),
    'submitted',coalesce((select s.submitted from public.quiz_submissions s where s.room_id=p_room_id and s.player_id=p.id),false)
  ) order by p.created_at) from public.quiz_players p where p.room_id=p_room_id),'[]'::jsonb);
end $$;

create or replace function public.my_questions(p_room_id uuid, p_player_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
begin
  perform public._assert_member(p_room_id,p_player_id);
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id',q.id,'type',q.type,'question_text',q.question_text,'options',q.options,
    'correct_answer',q.correct_answer,'explanation',q.explanation,'points',q.points,'image_path',q.image_path
  ) order by q.created_at) from public.quiz_questions q where q.room_id=p_room_id and q.author_id=p_player_id),'[]'::jsonb);
end $$;

create or replace function public.list_questions(p_room_id uuid, p_player_id uuid, p_include_answers boolean default false)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare r public.quiz_rooms; p public.quiz_players; outjson jsonb;
begin
  p:=public._assert_member(p_room_id,p_player_id);
  select * into r from public.quiz_rooms where id=p_room_id;
  if p_include_answers and r.status<>'revealed' then raise exception '尚未開放查看答案'; end if;
  select coalesce(jsonb_agg(
    jsonb_build_object('id',q.id,'type',q.type,'question_text',q.question_text,'options',q.options,'points',q.points,
      'image_path',q.image_path,
      'image_url',null)
    || case when r.status='revealed' and p_include_answers then jsonb_build_object(
      'correct_answer',q.correct_answer,'explanation',q.explanation,
      'author_nickname',(select nickname from public.quiz_players where id=q.author_id))
      else '{}'::jsonb end
    order by q.created_at
  ),'[]'::jsonb) into outjson from public.quiz_questions q where q.room_id=p_room_id;
  return outjson;
end $$;

create or replace function public.save_question(
  p_room_id uuid,p_player_id uuid,p_question_id uuid,p_type text,p_text text,p_options jsonb,
  p_correct_answer text,p_explanation text,p_points integer,p_image_path text
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare r public.quiz_rooms; p public.quiz_players; qid uuid; qcount int;
begin
  p:=public._assert_member(p_room_id,p_player_id);
  select * into r from public.quiz_rooms where id=p_room_id;
  if r.status<>'draft' then raise exception '題庫已鎖定'; end if;
  if p_type not in ('single','boolean','fill','short','image') then raise exception '題型不合法'; end if;
  if char_length(trim(p_text)) not between 1 and 1200 or char_length(trim(p_correct_answer))=0 then raise exception '題目或標準答案不可空白'; end if;
  if p_points not between 1 and 100 then raise exception '配分必須介於 1 到 100'; end if;
  if p_type='single' and (jsonb_typeof(p_options)<>'array' or jsonb_array_length(p_options)<2 or jsonb_array_length(p_options)>6) then raise exception '選擇題需要 2 到 6 個選項'; end if;
  if p_type='image' and p_image_path is null then raise exception '圖片題必須附圖'; end if;
  select count(*) into qcount from public.quiz_questions where room_id=p_room_id and author_id=p.id;
  if p_question_id is null and qcount>=10 then raise exception '每人最多 10 題'; end if;
  if p_question_id is not null then
    update public.quiz_questions set type=p_type,question_text=trim(p_text),options=coalesce(p_options,'[]'),
      correct_answer=trim(p_correct_answer),explanation=coalesce(p_explanation,''),points=p_points,
      image_path=p_image_path,updated_at=now()
    where id=p_question_id and room_id=p_room_id and author_id=p.id returning id into qid;
    if qid is null then raise exception '找不到可編輯的題目'; end if;
  else
    insert into public.quiz_questions(room_id,author_id,type,question_text,options,correct_answer,explanation,points,image_path)
      values(p_room_id,p.id,p_type,trim(p_text),coalesce(p_options,'[]'),trim(p_correct_answer),coalesce(p_explanation,''),p_points,p_image_path)
      returning id into qid;
  end if;
  return qid;
end $$;

create or replace function public.delete_question(p_room_id uuid,p_player_id uuid,p_question_id uuid)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare p public.quiz_players; r public.quiz_rooms;
begin
  p:=public._assert_member(p_room_id,p_player_id);
  select * into r from public.quiz_rooms where id=p_room_id;
  if r.status<>'draft' then raise exception '題庫已鎖定'; end if;
  delete from public.quiz_questions where id=p_question_id and room_id=p_room_id and author_id=p.id;
  return found;
end $$;

create or replace function public.lock_room(p_room_id uuid,p_player_id uuid)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare p public.quiz_players; r public.quiz_rooms; player_count int; qbad int;
begin
  p:=public._assert_member(p_room_id,p_player_id);
  if not p.is_host then raise exception '只有主持人可以鎖定題庫'; end if;
  select * into r from public.quiz_rooms where id=p_room_id;
  if r.status<>'draft' then raise exception '房間不是出題狀態'; end if;
  select count(*) into player_count from public.quiz_players where room_id=p_room_id;
  if player_count<2 then raise exception '至少需要 2 位參加者'; end if;
  select count(*) into qbad from public.quiz_players p2 where p2.room_id=p_room_id
    and (select count(*) from public.quiz_questions q where q.author_id=p2.id and q.room_id=p_room_id)<>10;
  if qbad>0 then raise exception '每位參加者都必須完成 10 題，才能鎖定題庫'; end if;
  update public.quiz_rooms set status='locked' where id=p_room_id;
  return true;
end $$;

create or replace function public.submit_answers(p_room_id uuid,p_player_id uuid,p_responses jsonb)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare p public.quiz_players; r public.quiz_rooms; qcount int; answered int;
begin
  p:=public._assert_member(p_room_id,p_player_id);
  select * into r from public.quiz_rooms where id=p_room_id;
  if r.status<>'locked' then raise exception '目前不是作答階段'; end if;
  select count(*) into qcount from public.quiz_questions where room_id=p_room_id;
  select count(*) into answered from jsonb_each_text(p_responses) where trim(value)<>'';
  if answered<>qcount then raise exception '請回答所有題目後再交卷'; end if;
  if exists(select 1 from public.quiz_submissions where room_id=p_room_id and player_id=p.id and submitted) then raise exception '你已經交卷'; end if;
  insert into public.quiz_submissions(room_id,player_id,responses,submitted,submitted_at)
    values(p_room_id,p.id,p_responses,true,now())
    on conflict(room_id,player_id) do update set responses=excluded.responses,submitted=true,submitted_at=now()
    where not public.quiz_submissions.submitted;
  return true;
end $$;

create or replace function public.submission_status(p_room_id uuid,p_player_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare p public.quiz_players;
begin
  p:=public._assert_member(p_room_id,p_player_id);
  return coalesce((select jsonb_agg(jsonb_build_object('player_id',s.player_id,'nickname',pl.nickname,
    'submitted',s.submitted,'responses',case
      when (select status from public.quiz_rooms where id=p_room_id)='revealed' then coalesce(s.responses,'{}'::jsonb)
      when s.player_id=p.id then coalesce(s.responses,'{}'::jsonb)
      else '{}'::jsonb end)
    order by pl.created_at) from public.quiz_players pl left join public.quiz_submissions s on s.room_id=pl.room_id and s.player_id=pl.id
    where pl.room_id=p_room_id),'[]'::jsonb);
end $$;

create or replace function public.reveal_answers(p_room_id uuid,p_player_id uuid)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare p public.quiz_players; r public.quiz_rooms;
begin
  p:=public._assert_member(p_room_id,p_player_id);
  if not p.is_host then raise exception '只有主持人可以公布答案'; end if;
  select * into r from public.quiz_rooms where id=p_room_id;
  if r.status<>'locked' then raise exception '目前不是作答階段'; end if;
  if exists(select 1 from public.quiz_players pl left join public.quiz_submissions s on s.room_id=pl.room_id and s.player_id=pl.id
    where pl.room_id=p_room_id and coalesce(s.submitted,false)=false) then
    raise exception '仍有人尚未交卷；如要強制公布，請先使用主持人管理流程';
  end if;
  update public.quiz_rooms set status='revealed',revealed_at=now() where id=p_room_id;
  return true;
end $$;

create or replace function public.save_manual_grades(p_room_id uuid,p_player_id uuid,p_grades jsonb)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare p public.quiz_players; item jsonb; q public.quiz_questions; target uuid; pts int;
begin
  p:=public._assert_member(p_room_id,p_player_id);
  if not p.is_host then raise exception '只有主持人可以評分'; end if;
  if (select status from public.quiz_rooms where id=p_room_id)<>'revealed' then raise exception '尚未公布答案'; end if;
  for item in select value from jsonb_array_elements(coalesce(p_grades,'[]')) loop
    select * into q from public.quiz_questions where id=(item->>'question_id')::uuid and room_id=p_room_id;
    if not found or q.type<>'short' then raise exception '簡答題資料不正確'; end if;
    target:=(item->>'player_id')::uuid; pts:=(item->>'points')::int;
    if pts<0 or pts>q.points then raise exception '評分超出範圍'; end if;
    if not exists(select 1 from public.quiz_submissions where room_id=p_room_id and player_id=target and submitted) then raise exception '該參加者尚未交卷'; end if;
    insert into public.quiz_manual_grades(room_id,player_id,question_id,awarded_points,grader_id)
      values(p_room_id,target,q.id,pts,p.id)
      on conflict(room_id,player_id,question_id) do update set awarded_points=excluded.awarded_points,grader_id=excluded.grader_id,updated_at=now();
  end loop;
  return true;
end $$;

create or replace function public.get_results(p_room_id uuid,p_player_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare p public.quiz_players; r public.quiz_rooms;
begin
  p:=public._assert_member(p_room_id,p_player_id);
  select * into r from public.quiz_rooms where id=p_room_id;
  if r.status<>'revealed' then raise exception '尚未公布答案'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('player_id',pl.id,'nickname',pl.nickname,'question_id',q.id,
      'awarded_points',case when q.type='short' then coalesce(mg.awarded_points,0)
        when lower(trim(s.responses->>q.id))=lower(trim(q.correct_answer))
          or (q.type='fill' and exists(select 1 from unnest(string_to_array(q.correct_answer,'|')) a where lower(trim(a))=lower(trim(s.responses->>q.id))))
        then q.points else 0 end,
      'max_points',q.points,'pending_manual',(q.type='short' and mg.question_id is null))
    order by pl.created_at,q.created_at)
    from public.quiz_players pl
    join public.quiz_questions q on q.room_id=pl.room_id
    join public.quiz_submissions s on s.room_id=pl.room_id and s.player_id=pl.id and s.submitted
    left join public.quiz_manual_grades mg on mg.room_id=q.room_id and mg.player_id=pl.id and mg.question_id=q.id
    where pl.room_id=p_room_id
  ),'[]'::jsonb);
end $$;

-- RPC access. Supabase PostgREST passes p_player_id from the browser; this lightweight
-- prototype is suitable for a friendly private event, not adversarial/public high-stakes use.
grant execute on function public.create_room(text,text,text) to anon, authenticated;
grant execute on function public.join_room(text,text,text) to anon, authenticated;
grant execute on function public.get_room_state(uuid,uuid) to anon, authenticated;
grant execute on function public.list_players(uuid,uuid) to anon, authenticated;
grant execute on function public.my_questions(uuid,uuid) to anon, authenticated;
grant execute on function public.list_questions(uuid,uuid,boolean) to anon, authenticated;
grant execute on function public.save_question(uuid,uuid,uuid,text,text,jsonb,text,text,integer,text) to anon, authenticated;
grant execute on function public.delete_question(uuid,uuid,uuid) to anon, authenticated;
grant execute on function public.lock_room(uuid,uuid) to anon, authenticated;
grant execute on function public.submit_answers(uuid,uuid,jsonb) to anon, authenticated;
grant execute on function public.submission_status(uuid,uuid) to anon, authenticated;
grant execute on function public.reveal_answers(uuid,uuid) to anon, authenticated;
grant execute on function public.save_manual_grades(uuid,uuid,jsonb) to anon, authenticated;
grant execute on function public.get_results(uuid,uuid) to anon, authenticated;

-- IMPORTANT:
-- For stronger production security, replace client-supplied player IDs with a real authenticated
-- Supabase Auth identity or a server-issued signed session token. Rate-limit room joins and PIN attempts.
-- Never expose the database service_role key in config.js.
