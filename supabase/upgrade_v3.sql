-- Friends Quiz v3 incremental upgrade: run AFTER upgrade_v2.sql, with DB backup.
-- Existing v2 rooms and answered questions remain; do not rerun schema.sql.
BEGIN;
ALTER TABLE public.quiz_questions ADD COLUMN IF NOT EXISTS option_image_paths jsonb NOT NULL DEFAULT '[]'::jsonb;
-- Remove old 10-argument RPC so PostgREST cannot resolve competing save_question signatures.
DROP FUNCTION IF EXISTS public.save_question(uuid,uuid,uuid,text,text,jsonb,text,text,integer,text);
create or replace function public.my_questions(p_room_id uuid, p_player_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
begin
  perform public._assert_member(p_room_id,p_player_id);
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id',q.id,'type',q.type,'question_text',q.question_text,'options',q.options,
    'correct_answer',q.correct_answer,'explanation',q.explanation,'points',q.points,'image_path',q.image_path,'option_image_paths',q.option_image_paths
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
      'image_path',q.image_path,'option_image_paths',q.option_image_paths,
      'image_url',null)
    || case when r.status='revealed' and p_include_answers then jsonb_build_object(
      'correct_answer',q.correct_answer,'explanation',q.explanation,
      'author_nickname',(select nickname from public.quiz_players where id=q.author_id))
      else '{}'::jsonb end
    order by q.created_at
  ),'[]'::jsonb) into outjson from public.quiz_questions q where q.room_id=p_room_id and (p_include_answers or q.author_id<>p.id);
  return outjson;
end $$;

create or replace function public.save_question(
  p_room_id uuid,p_player_id uuid,p_question_id uuid,p_type text,p_text text,p_options jsonb,
  p_correct_answer text,p_explanation text,p_points integer,p_image_path text,p_option_images jsonb
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare r public.quiz_rooms; p public.quiz_players; qid uuid; qcount int; used_points int; minimum_remaining int;
begin
  p:=public._assert_member(p_room_id,p_player_id);
  select * into r from public.quiz_rooms where id=p_room_id;
  if r.status<>'draft' then raise exception '題庫已鎖定'; end if;
  if p_type not in ('single','boolean','fill','short') then raise exception '題型不合法'; end if;
  if char_length(trim(p_text)) not between 1 and 1200 or char_length(trim(p_correct_answer))=0 then raise exception '題目或標準答案不可空白'; end if;
  if p_points not between 1 and 100 then raise exception '配分必須介於 1 到 100'; end if;
  if p_type='single' and (jsonb_typeof(p_options)<>'array' or jsonb_array_length(p_options)<>4) then raise exception '選擇題需要 2 到 6 個選項'; end if;
  if p_type='boolean' and p_correct_answer not in ('是','否') then raise exception '是非題答案必須為是或否'; end if;
  if p_type='single' and not (p_options ? p_correct_answer) then raise exception '正確答案必須是四個選項之一'; end if;
  if p_type='single' and (jsonb_typeof(p_option_images)<>'array' or jsonb_array_length(p_option_images)<>4) then raise exception '選項圖片格式不正確'; end if;
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
      image_path=p_image_path,option_image_paths=case when p_type='single' then p_option_images else '[]'::jsonb end,updated_at=now()
    where id=p_question_id and room_id=p_room_id and author_id=p.id returning id into qid;
    if qid is null then raise exception '找不到可編輯的題目'; end if;
  else
    insert into public.quiz_questions(room_id,author_id,type,question_text,options,correct_answer,explanation,points,image_path,option_image_paths)
      values(p_room_id,p.id,p_type,trim(p_text),coalesce(p_options,'[]'),trim(p_correct_answer),coalesce(p_explanation,''),p_points,p_image_path,case when p_type='single' then p_option_images else '[]'::jsonb end)
      returning id into qid;
  end if;
  return qid;
end $$;

create or replace function public.submit_answers(p_room_id uuid,p_player_id uuid,p_responses jsonb)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare p public.quiz_players; r public.quiz_rooms; expected int; supplied int;
begin
 p:=public._assert_member(p_room_id,p_player_id);
 select * into r from public.quiz_rooms where id=p_room_id;
 if r.status<>'locked' then raise exception '目前不是作答階段'; end if;
 if jsonb_typeof(p_responses)<>'object' then raise exception '答案格式不正確'; end if;
 select count(*) into expected from public.quiz_questions q where q.room_id=p_room_id and q.author_id<>p.id;
 select count(*) into supplied from jsonb_each_text(p_responses) where trim(value)<>'';
 if supplied<>expected or exists(
  select 1 from jsonb_each_text(p_responses) a
  where trim(a.value)='' or not exists(
   select 1 from public.quiz_questions q where q.room_id=p_room_id and q.author_id<>p.id and q.id::text=a.key
  )
 ) then raise exception '請完整回答其他出題者的所有題目（不可提交自己的題目）'; end if;
 if exists(select 1 from public.quiz_submissions where room_id=p_room_id and player_id=p.id and submitted) then raise exception '你已經交卷'; end if;
 insert into public.quiz_submissions(room_id,player_id,responses,submitted,submitted_at)
 values(p_room_id,p.id,p_responses,true,now())
 on conflict(room_id,player_id) do update set responses=excluded.responses,submitted=true,submitted_at=now()
 where not public.quiz_submissions.submitted;
 return true;
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
 where q.room_id=p_room_id and q.author_id=p.id and q.type='short' and s.player_id<>q.author_id
 on conflict(room_id,question_id,player_id) do nothing;
 return coalesce((select jsonb_agg(jsonb_build_object(
  'token',t.token,'nickname',pl.nickname,'question_text',q.question_text,'response',s.responses->>(q.id::text),
  'correct_answer',q.correct_answer,'max_points',q.points,'awarded_points',g.awarded_points)
  order by q.created_at,t.token)
 from public.quiz_grade_tokens t
 join public.quiz_questions q on q.id=t.question_id and q.room_id=t.room_id
 join public.quiz_submissions s on s.room_id=t.room_id and s.player_id=t.player_id and s.submitted
 join public.quiz_players pl on pl.room_id=t.room_id and pl.id=t.player_id
 left join public.quiz_manual_grades g on g.room_id=t.room_id and g.player_id=t.player_id and g.question_id=t.question_id
 where t.room_id=p_room_id and q.author_id=p.id and q.type='short' and t.player_id<>q.author_id),'[]'::jsonb);
end $$;

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
    when q.type='single' and lower(trim(s.responses->>(q.id::text)))=lower(trim(q.correct_answer)) then q.points
    when q.type='fill' and exists(select 1 from unnest(string_to_array(q.correct_answer,'|')) as a where lower(trim(a))=lower(trim(s.responses->>(q.id::text))) ) then q.points
    else 0 end) as total,
    sum(q.points) as max,
    bool_or(q.type='short' and g.question_id is null) as pending
   from public.quiz_submissions s
   join public.quiz_questions q on q.room_id=s.room_id and q.author_id<>s.player_id
   left join public.quiz_manual_grades g on g.room_id=s.room_id and g.player_id=s.player_id and g.question_id=q.id
   where s.room_id=p_room_id and s.player_id=pl.id and s.submitted
  ) score on true
  where pl.room_id=p_room_id and exists(select 1 from public.quiz_submissions s where s.room_id=pl.room_id and s.player_id=pl.id and s.submitted)
 ),'[]'::jsonb);
end $$;

GRANT EXECUTE ON FUNCTION public.save_question(uuid,uuid,uuid,text,text,jsonb,text,text,integer,text,jsonb) TO anon,authenticated;
-- The v2 queue/save grading RPCs continue to be used; queue now exposes player nickname.
COMMIT;
