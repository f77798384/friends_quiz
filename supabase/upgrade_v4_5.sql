-- Friends Quiz v4.5：僅限尚未有交卷的 locked 房間解鎖；修復題庫讀取與圖片路徑
BEGIN;
CREATE OR REPLACE FUNCTION public.unlock_room(p_room_id uuid,p_player_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_player public.quiz_players; v_status public.quiz_room_status;
BEGIN
  v_player:=public._assert_member(p_room_id,p_player_id);
  IF NOT v_player.is_host THEN RAISE EXCEPTION '只有主持人可以解鎖'; END IF;
  SELECT status INTO v_status FROM public.quiz_rooms WHERE id=p_room_id FOR UPDATE;
  IF v_status IS DISTINCT FROM 'locked' THEN RAISE EXCEPTION '只有已鎖定且尚未公布答案的房間可以解鎖'; END IF;
  IF EXISTS(SELECT 1 FROM public.quiz_submissions WHERE room_id=p_room_id AND submitted) THEN
    RAISE EXCEPTION '已有玩家交卷，為保護作答公平性不能解鎖';
  END IF;
  UPDATE public.quiz_rooms SET status='draft' WHERE id=p_room_id;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.unlock_room(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.unlock_room(uuid,uuid) TO anon,authenticated;
CREATE OR REPLACE FUNCTION public.list_questions(
 p_room_id uuid,p_player_id uuid,p_include_answers boolean DEFAULT false
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_room public.quiz_rooms; v_player public.quiz_players;
BEGIN
 v_player:=public._assert_member(p_room_id,p_player_id);
 SELECT * INTO v_room FROM public.quiz_rooms WHERE id=p_room_id;
 IF p_include_answers AND v_room.status<>'revealed' THEN RAISE EXCEPTION '尚未開放查看答案'; END IF;
 RETURN COALESCE((
 SELECT jsonb_agg(
  jsonb_build_object(
   'id',q.id,'author_id',q.author_id,'type',q.type,
   'question_text',q.question_text,'options',q.options,'points',q.points,
   'image_path',q.image_path,'option_image_paths',COALESCE(q.option_image_paths,'[]'::jsonb)
  ) || CASE WHEN p_include_answers AND v_room.status='revealed'
    THEN jsonb_build_object('correct_answer',q.correct_answer,'explanation',q.explanation,
      'author_nickname',(SELECT nickname FROM public.quiz_players WHERE id=q.author_id))
    ELSE '{}'::jsonb END
  ORDER BY q.created_at
 ) FROM public.quiz_questions q
 WHERE q.room_id=p_room_id AND
   ((p_include_answers AND v_room.status='revealed') OR q.author_id<>v_player.id)
 ),'[]'::jsonb);
END $$;
COMMIT;
NOTIFY pgrst,'reload schema';
