-- Friends Quiz v4.5.2 — 修復人工閱卷顯示姓名、排除出題者自己
-- 請先備份資料庫；適用已完成 v4.5.1 升級的專案。
BEGIN;

-- 僅向該題出題者回傳作答紀錄，並以 quiz_players 的暱稱呈現。
CREATE OR REPLACE FUNCTION public.get_grading_queue(p_room_id uuid,p_player_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE p public.quiz_players;
BEGIN
  p:=public._assert_member(p_room_id,p_player_id);
  IF (SELECT status FROM public.quiz_rooms WHERE id=p_room_id) <> 'revealed' THEN
    RETURN '[]'::jsonb;
  END IF;

  INSERT INTO public.quiz_grade_tokens(room_id,question_id,player_id)
  SELECT q.room_id,q.id,s.player_id
  FROM public.quiz_questions q
  JOIN public.quiz_submissions s ON s.room_id=q.room_id AND s.submitted=true
  WHERE q.room_id=p_room_id AND q.author_id=p.id AND q.type='short'
    AND s.player_id<>q.author_id
    AND s.responses ? q.id::text
  ON CONFLICT(room_id,question_id,player_id) DO NOTHING;

  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'token',t.token,
      'nickname',pl.nickname,
      'question_text',q.question_text,
      'response',s.responses->>(q.id::text),
      'correct_answer',q.correct_answer,
      'max_points',q.points,
      'awarded_points',g.awarded_points
    ) ORDER BY q.created_at,t.token)
    FROM public.quiz_grade_tokens t
    JOIN public.quiz_questions q ON q.room_id=t.room_id AND q.id=t.question_id
    JOIN public.quiz_submissions s ON s.room_id=t.room_id AND s.player_id=t.player_id AND s.submitted=true
    JOIN public.quiz_players pl ON pl.room_id=t.room_id AND pl.id=t.player_id
    LEFT JOIN public.quiz_manual_grades g ON g.room_id=t.room_id
      AND g.player_id=t.player_id AND g.question_id=t.question_id
    WHERE t.room_id=p_room_id AND q.author_id=p.id AND q.type='short'
      AND t.player_id<>q.author_id AND s.responses ? q.id::text
  ),'[]'::jsonb);
END $$;

-- 即使資料庫裡保留舊版錯誤建立的「自己評自己」token，也必須禁止送分。
CREATE OR REPLACE FUNCTION public.save_anonymous_grades(
  p_room_id uuid,p_player_id uuid,p_grades jsonb
) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE item jsonb; t public.quiz_grade_tokens; q public.quiz_questions;
  pts integer; p public.quiz_players;
BEGIN
  p:=public._assert_member(p_room_id,p_player_id);
  IF (SELECT status FROM public.quiz_rooms WHERE id=p_room_id) <> 'revealed' THEN
    RAISE EXCEPTION '尚未公布答案';
  END IF;
  IF jsonb_typeof(p_grades) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION '評分格式錯誤';
  END IF;
  FOR item IN SELECT value FROM jsonb_array_elements(p_grades) LOOP
    SELECT * INTO t FROM public.quiz_grade_tokens
    WHERE token=(item->>'token')::uuid AND room_id=p_room_id;
    IF NOT FOUND THEN RAISE EXCEPTION '無權批改此答案'; END IF;
    SELECT * INTO q FROM public.quiz_questions
    WHERE id=t.question_id AND room_id=p_room_id
      AND author_id=p.id AND type='short';
    IF NOT FOUND OR t.player_id=p.id OR t.player_id=q.author_id THEN
      RAISE EXCEPTION '不能批改自己的答案，且只能批改自己出的簡答題';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.quiz_submissions s
      WHERE s.room_id=p_room_id AND s.player_id=t.player_id
        AND s.submitted=true AND s.responses ? q.id::text
    ) THEN RAISE EXCEPTION '此玩家沒有提交這道題目的答案'; END IF;
    pts:=(item->>'points')::integer;
    IF pts IS NULL OR pts<0 OR pts>q.points THEN
      RAISE EXCEPTION '給分超出範圍';
    END IF;
    INSERT INTO public.quiz_manual_grades(room_id,player_id,question_id,awarded_points,grader_id)
    VALUES(p_room_id,t.player_id,t.question_id,pts,p.id)
    ON CONFLICT(room_id,player_id,question_id) DO UPDATE
      SET awarded_points=excluded.awarded_points,grader_id=excluded.grader_id,updated_at=now();
  END LOOP;
  RETURN true;
END $$;

-- 清理過去錯誤產生的自己評自己紀錄（不刪除有效玩家作答）。
DELETE FROM public.quiz_manual_grades g USING public.quiz_questions q
WHERE g.question_id=q.id AND g.room_id=q.room_id AND g.player_id=q.author_id;
DELETE FROM public.quiz_grade_tokens t USING public.quiz_questions q
WHERE t.question_id=q.id AND t.room_id=q.room_id AND t.player_id=q.author_id;

REVOKE ALL ON FUNCTION public.get_grading_queue(uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.save_anonymous_grades(uuid,uuid,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_grading_queue(uuid,uuid) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.save_anonymous_grades(uuid,uuid,jsonb) TO anon,authenticated;
COMMIT;
NOTIFY pgrst, 'reload schema';
