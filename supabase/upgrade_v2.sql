-- Friends Quiz v2 incremental upgrade. Run once in Supabase SQL Editor.
-- BEFORE: backup database. Existing rooms/questions/submissions are retained.
-- Prototype image bucket is PUBLIC READABLE: do not upload private/sensitive images.

create table if not exists public.quiz_grade_tokens (
 token uuid primary key default gen_random_uuid(),
 room_id uuid not null,
 question_id uuid not null,
 player_id uuid not null,
 unique(room_id,question_id,player_id),
 foreign key(room_id,question_id) references public.quiz_questions(room_id,id) on delete cascade,
 foreign key(room_id,player_id) references public.quiz_players(room_id,id) on delete cascade
);
alter table public.quiz_grade_tokens enable row level security;
revoke all on public.quiz_grade_tokens from anon, authenticated;

-- Existing v1 grading RPC exposes target identities, so remove public execute grants.
revoke execute on function public.save_manual_grades(uuid,uuid,jsonb) from public, anon, authenticated;

-- Storage: public pictures readable by anyone with the URL. Anonymous upload is
-- restricted to a shaped path, MIME and 5 MB, but is NOT authenticated to a player.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 values('quiz-images','quiz-images',true,5242880,array['image/jpeg','image/png','image/webp'])
 on conflict (id) do update set public=true,file_size_limit=5242880,allowed_mime_types=excluded.allowed_mime_types;
drop policy if exists "quiz_images_v2_upload" on storage.objects;
create policy "quiz_images_v2_upload" on storage.objects for insert to anon,authenticated
 with check (bucket_id='quiz-images' and name ~ '^[a-f0-9-]{36}/[a-f0-9-]{36}/[a-f0-9-]{36}\.(jpg|png|webp)$');

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
declare r public.quiz_rooms; p public.quiz_players; qid uuid; qcount int; used_points int; minimum_remaining int;
begin
  p:=public._assert_member(p_room_id,p_player_id);
  select * into r from public.quiz_rooms where id=p_room_id;
  if r.status<>'draft' then raise exception '題庫已鎖定'; end if;
  if p_type not in ('single','boolean','fill','short','image') then raise exception '題型不合法'; end if;
  if char_length(trim(p_text)) not between 1 and 1200 or char_length(trim(p_correct_answer))=0 then raise exception '題目或標準答案不可空白'; end if;
  if p_points not between 1 and 100 then raise exception '配分必須介於 1 到 100'; end if;
  if p_type='single' and (jsonb_typeof(p_options)<>'array' or jsonb_array_length(p_options)<>4) then raise exception '選擇題需要 2 到 6 個選項'; end if;
  if p_type='boolean' and p_correct_answer not in ('是','否') then raise exception '是非題答案必須為是或否'; end if;
  if p_type='single' and not (p_options ? p_correct_answer) then raise exception '正確答案必須是四個選項之一'; end if;
  if p_type='image' and p_image_path is null then raise exception '圖片題必須附圖'; end if;
  select count(*) into qcount from public.quiz_questions where room_id=p_room_id and author_id=p.id;
  if p_question_id is null and qcount>=10 then raise exception '每人最多 10 題'; end if;
  if p_question_id is not null and not exists (select 1 from public.quiz_questions
      where id=p_question_id and room_id=p_room_id and author_id=p.id) then raise exception '找不到可編輯的題目'; end if;
  select coalesce(sum(points),0) into used_points from public.quiz_questions
   where room_id=p_room_id and author_id=p.id and (p_question_id is null or id<>p_question_id);
  minimum_remaining:=10-qcount-case when p_question_id is null then 1 else 0 end;
  if used_points+p_points+minimum_remaining>100 then raise exception '配分過高：必須為剩餘題目保留至少 1 分'; end if;
  if minimum_remaining=0 and used_points+p_points<>100 then raise exception '第十題必須補足總分 100 分'; end if;
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
  if exists(select 1 from public.quiz_questions where room_id=p_room_id group by author_id having sum(points)<>100) then raise exception '每位出題者的總配分必須為 100 分'; end if;
  update public.quiz_rooms set status='locked' where id=p_room_id;
  return true;
end $$;

create or replace function public.submission_status(p_room_id uuid,p_player_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare p public.quiz_players;
begin
  p:=public._assert_member(p_room_id,p_player_id);
  return coalesce((select jsonb_agg(jsonb_build_object('player_id',s.player_id,'nickname',pl.nickname,
    'submitted',s.submitted,'responses',case
      when s.player_id=p.id then coalesce(s.responses,'{}'::jsonb)
      else '{}'::jsonb end)
    order by pl.created_at) from public.quiz_players pl left join public.quiz_submissions s on s.room_id=pl.room_id and s.player_id=pl.id
    where pl.room_id=p_room_id),'[]'::jsonb);
end $$;

create or replace function public.get_grading_queue(p_room_id uuid,p_player_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare p public.quiz_players;
begin
 p:=public._assert_member(p_room_id,p_player_id);
 if (select status from public.quiz_rooms where id=p_room_id)<>'revealed' then return '[]'::jsonb; end if;
 insert into public.quiz_grade_tokens(room_id,question_id,player_id)
 select q.room_id,q.id,s.player_id from public.quiz_questions q
 join public.quiz_submissions s on s.room_id=q.room_id and s.submitted
 where q.room_id=p_room_id and q.author_id=p.id and q.type='short'
 on conflict(room_id,question_id,player_id) do nothing;
 return coalesce((select jsonb_agg(jsonb_build_object(
  'token',t.token,'question_text',q.question_text,'response',s.responses->>(q.id::text),
  'correct_answer',q.correct_answer,'max_points',q.points,'awarded_points',g.awarded_points)
  order by q.created_at,t.token)
 from public.quiz_grade_tokens t
 join public.quiz_questions q on q.id=t.question_id and q.room_id=t.room_id
 join public.quiz_submissions s on s.room_id=t.room_id and s.player_id=t.player_id and s.submitted
 left join public.quiz_manual_grades g on g.room_id=t.room_id and g.player_id=t.player_id and g.question_id=t.question_id
 where t.room_id=p_room_id and q.author_id=p.id and q.type='short'),'[]'::jsonb);
end $$;

create or replace function public.save_anonymous_grades(p_room_id uuid,p_player_id uuid,p_grades jsonb)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare item jsonb; t public.quiz_grade_tokens; q public.quiz_questions; pts int;
begin
 perform public._assert_member(p_room_id,p_player_id);
 if (select status from public.quiz_rooms where id=p_room_id)<>'revealed' then raise exception '尚未公布答案'; end if;
 if jsonb_typeof(p_grades)<>'array' then raise exception '評分格式錯誤'; end if;
 for item in select value from jsonb_array_elements(p_grades) loop
  select * into t from public.quiz_grade_tokens where token=(item->>'token')::uuid and room_id=p_room_id;
  if not found then raise exception '無權批改此答案'; end if;
  select * into q from public.quiz_questions where id=t.question_id and room_id=p_room_id and author_id=p_player_id and type='short';
  if not found then raise exception '只能批改自己的簡答題'; end if;
  pts:=(item->>'points')::int;
  if pts is null or pts<0 or pts>q.points then raise exception '給分超出範圍'; end if;
  insert into public.quiz_manual_grades(room_id,player_id,question_id,awarded_points,grader_id)
   values(p_room_id,t.player_id,t.question_id,pts,p_player_id)
   on conflict(room_id,player_id,question_id) do update
   set awarded_points=excluded.awarded_points,grader_id=excluded.grader_id,updated_at=now();
 end loop;
 return true;
end $$;

-- Aggregated scoreboard only: no answer text, no per-question grading linkage.
create or replace function public.get_results(p_room_id uuid,p_player_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
begin
 perform public._assert_member(p_room_id,p_player_id);
 if (select status from public.quiz_rooms where id=p_room_id)<>'revealed' then raise exception '尚未公布答案'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object(
   'nickname',pl.nickname,'total',coalesce(score.total,0),'max',coalesce(score.max,0),
   'pending',coalesce(score.pending,false)) order by pl.created_at)
  from public.quiz_players pl
  left join lateral (
   select sum(case when q.type='short' then coalesce(g.awarded_points,0)
    when q.type='boolean' and (case when lower(trim(s.responses->>(q.id::text))) in ('是','true') then '是' when lower(trim(s.responses->>(q.id::text))) in ('否','false') then '否' else '' end)
      =(case when lower(trim(q.correct_answer)) in ('是','true') then '是' else '否' end) then q.points
    when q.type in ('single','image') and lower(trim(s.responses->>(q.id::text)))=lower(trim(q.correct_answer)) then q.points
    when q.type='fill' and exists(select 1 from unnest(string_to_array(q.correct_answer,'|')) as a where lower(trim(a))=lower(trim(s.responses->>(q.id::text))) ) then q.points
    else 0 end) as total,
    sum(q.points) as max,
    bool_or(q.type='short' and g.question_id is null) as pending
   from public.quiz_submissions s
   join public.quiz_questions q on q.room_id=s.room_id
   left join public.quiz_manual_grades g on g.room_id=s.room_id and g.player_id=s.player_id and g.question_id=q.id
   where s.room_id=p_room_id and s.player_id=pl.id and s.submitted
  ) score on true
  where pl.room_id=p_room_id and exists(select 1 from public.quiz_submissions s where s.room_id=pl.room_id and s.player_id=pl.id and s.submitted)
 ),'[]'::jsonb);
end $$;

grant execute on function public.get_grading_queue(uuid,uuid),public.save_anonymous_grades(uuid,uuid,jsonb) to anon,authenticated;
