-- Friends Quiz v4.4.3: 修正 my_questions 未回傳已儲存圖片路徑的問題。
-- 適用已執行 v4.3 的資料庫。執行前請備份。
BEGIN;
ALTER TABLE public.quiz_questions
  ADD COLUMN IF NOT EXISTS option_image_paths jsonb NOT NULL DEFAULT '[]'::jsonb;

CREATE OR REPLACE FUNCTION public.my_questions(p_room_id uuid, p_player_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  PERFORM public._assert_member(p_room_id,p_player_id);
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'id',q.id,'type',q.type,'question_text',q.question_text,'options',q.options,
    'correct_answer',q.correct_answer,'explanation',q.explanation,
    'points',q.points,'image_path',q.image_path,
    'option_image_paths',COALESCE(q.option_image_paths,'[]'::jsonb)
  ) ORDER BY q.created_at)
  FROM public.quiz_questions q
  WHERE q.room_id=p_room_id AND q.author_id=p_player_id),'[]'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.my_questions(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_questions(uuid,uuid) TO anon,authenticated;
COMMIT;
NOTIFY pgrst, 'reload schema';

-- 可選查核：查看已儲存圖片路徑（請勿分享包含私人資訊的查詢結果）。
-- SELECT id, image_path, option_image_paths FROM public.quiz_questions ORDER BY created_at DESC LIMIT 10;
