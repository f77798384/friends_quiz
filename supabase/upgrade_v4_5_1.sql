-- Friends Quiz v4.5.1 — 修正只回答其他人題目後仍無法交卷
-- 適用已完成 v4.5 升級的資料庫；只替換交卷驗證函式，不清除資料。
BEGIN;

CREATE OR REPLACE FUNCTION public.submit_answers(
  p_room_id uuid,
  p_player_id uuid,
  p_responses jsonb
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_player public.quiz_players;
  v_room public.quiz_rooms;
  v_expected integer;
  v_supplied integer;
BEGIN
  v_player := public._assert_member(p_room_id, p_player_id);

  SELECT * INTO v_room
  FROM public.quiz_rooms
  WHERE id = p_room_id;

  IF v_room.status IS DISTINCT FROM 'locked' THEN
    RAISE EXCEPTION '目前不是作答階段';
  END IF;

  IF p_responses IS NULL OR jsonb_typeof(p_responses) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION '答案格式不正確';
  END IF;

  -- 注意：僅計算「其他玩家出的題目」，與作答畫面一致。
  SELECT count(*) INTO v_expected
  FROM public.quiz_questions q
  WHERE q.room_id = p_room_id
    AND q.author_id <> v_player.id;

  SELECT count(*) INTO v_supplied
  FROM jsonb_each_text(p_responses);

  -- 所有題目都必須回答，且不接受自己的題目、其他房間題目或空答案。
  IF v_supplied <> v_expected OR EXISTS (
    SELECT 1
    FROM jsonb_each_text(p_responses) AS a(key, value)
    WHERE a.value IS NULL
       OR btrim(a.value) = ''
       OR NOT EXISTS (
         SELECT 1
         FROM public.quiz_questions q
         WHERE q.id::text = a.key
           AND q.room_id = p_room_id
           AND q.author_id <> v_player.id
       )
  ) THEN
    RAISE EXCEPTION '請完整回答其他出題者的所有題目（不可提交自己的題目）';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.quiz_submissions
    WHERE room_id = p_room_id
      AND player_id = v_player.id
      AND submitted = true
  ) THEN
    RAISE EXCEPTION '你已經交卷';
  END IF;

  INSERT INTO public.quiz_submissions
    (room_id, player_id, responses, submitted, submitted_at)
  VALUES
    (p_room_id, v_player.id, p_responses, true, now())
  ON CONFLICT (room_id, player_id)
  DO UPDATE SET
    responses = EXCLUDED.responses,
    submitted = true,
    submitted_at = now()
  WHERE NOT public.quiz_submissions.submitted;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.submit_answers(uuid,uuid,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_answers(uuid,uuid,jsonb) TO anon, authenticated;

COMMIT;
NOTIFY pgrst, 'reload schema';
