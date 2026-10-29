-- Friends Quiz v4.2: 修復 jsonb ->> bigint 錯誤
-- 適用已執行 upgrade_v4_1.sql 的資料庫，不刪除現有資料。
-- 問題：WITH ORDINALITY 的 idx 為 bigint，jsonb ->> 僅接受 text 或 integer。
BEGIN;
CREATE OR REPLACE FUNCTION public.save_question(
  p_room_id uuid,p_player_id uuid,p_question_id uuid,p_type text,p_text text,p_options jsonb,
  p_correct_answer text,p_explanation text,p_points integer,p_image_path text,p_option_images jsonb
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare r public.quiz_rooms; p public.quiz_players; qid uuid; qcount int; used_points int; minimum_remaining int;
begin
  p:=public._assert_member(p_room_id,p_player_id);
  select * into r from public.quiz_rooms where id=p_room_id;
  if r.status<>'draft' then raise exception '題庫已鎖定'; end if;
  if p_type not in ('single','boolean','fill','short') then raise exception '題型不合法'; end if;
  if char_length(trim(coalesce(p_text,'')))>1200 or (nullif(trim(coalesce(p_text,'')),'') is null and nullif(trim(coalesce(p_image_path,'')),'') is null) then raise exception '題幹需要文字或圖片'; end if;
  if nullif(trim(coalesce(p_correct_answer,'')),'') is null then raise exception '標準答案不可空白'; end if;
  if p_points not between 1 and 100 then raise exception '配分必須介於 1 到 100'; end if;
  if p_type='single' and (jsonb_typeof(p_options)<>'array' or jsonb_array_length(p_options)<>4) then raise exception '選擇題需要 2 到 6 個選項'; end if;
  if p_type='boolean' and p_correct_answer not in ('是','否') then raise exception '是非題答案必須為是或否'; end if;
  if p_type='single' and not (p_options ? p_correct_answer) then raise exception '正確答案必須是四個選項之一'; end if;
  if p_type='single' and exists (
    select 1 from jsonb_array_elements_text(p_options) with ordinality as o(value,idx)
    where nullif(trim(o.value),'') is null or
      (o.value like '__FQ_IMAGE_ONLY_%' and (p_option_images->>((o.idx-1)::integer)) is null)
  ) then raise exception '每個選項都必須包含文字或圖片'; end if;
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

COMMIT;
NOTIFY pgrst, 'reload schema';
