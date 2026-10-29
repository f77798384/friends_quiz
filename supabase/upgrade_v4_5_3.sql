-- v4.5.3: 公布後的作答檢視；只有房間成員可查詢，不含未提交的草稿。
BEGIN;
CREATE OR REPLACE FUNCTION public.get_review_responses(p_room_id uuid,p_player_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  PERFORM public._assert_member(p_room_id,p_player_id);
  IF NOT EXISTS(SELECT 1 FROM public.quiz_rooms WHERE id=p_room_id AND status='revealed') THEN
    RAISE EXCEPTION '尚未公布答案';
  END IF;
  RETURN COALESCE((
   SELECT jsonb_agg(jsonb_build_object('player_id',s.player_id,'nickname',pl.nickname,
     'responses',COALESCE((SELECT jsonb_object_agg(q.id::text,s.responses->(q.id::text))
      FROM public.quiz_questions q WHERE q.room_id=p_room_id AND q.author_id<>s.player_id
       AND s.responses ? q.id::text),'{}'::jsonb)) ORDER BY pl.nickname)
   FROM public.quiz_submissions s
   JOIN public.quiz_players pl ON pl.id=s.player_id AND pl.room_id=s.room_id
   WHERE s.room_id=p_room_id AND s.submitted=true
  ),'[]'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.get_review_responses(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_review_responses(uuid,uuid) TO anon, authenticated;
COMMIT;
NOTIFY pgrst,'reload schema';
