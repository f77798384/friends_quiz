-- Friends Quiz v4.6 混合測驗模式（接續 v4.5.5）
-- 先備份資料庫；此升級不清除既有玩家、房間、題目或成績。
BEGIN;
ALTER TABLE public.quiz_players ADD COLUMN IF NOT EXISTS player_role text NOT NULL DEFAULT 'author';
DO $$ BEGIN
 IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='quiz_players_role_check' AND conrelid='public.quiz_players'::regclass) THEN
  ALTER TABLE public.quiz_players ADD CONSTRAINT quiz_players_role_check CHECK (player_role IN ('author','answer_only'));
 END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.quiz_paper_exams (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 room_id uuid NOT NULL REFERENCES public.quiz_rooms(id) ON DELETE CASCADE,
 author_id uuid NOT NULL,
 title text NOT NULL CHECK (length(btrim(title)) BETWEEN 1 AND 120),
 max_points integer NOT NULL CHECK (max_points BETWEEN 1 AND 10000),
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE (room_id,id),
 FOREIGN KEY (room_id,author_id) REFERENCES public.quiz_players(room_id,id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS public.quiz_paper_scores (
 room_id uuid NOT NULL,
 exam_id uuid NOT NULL,
 player_id uuid NOT NULL,
 points integer NOT NULL CHECK (points >= 0),
 updated_at timestamptz NOT NULL DEFAULT now(),
 updated_by uuid NOT NULL REFERENCES public.quiz_players(id),
 PRIMARY KEY(exam_id,player_id),
 FOREIGN KEY(room_id,exam_id) REFERENCES public.quiz_paper_exams(room_id,id) ON DELETE CASCADE,
 FOREIGN KEY(room_id,player_id) REFERENCES public.quiz_players(room_id,id) ON DELETE CASCADE
);
ALTER TABLE public.quiz_paper_exams ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quiz_paper_scores ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.quiz_paper_exams,public.quiz_paper_scores FROM anon,authenticated,public;

-- 新玩家在 draft 階段是出題者；locked 階段是純作答者；revealed 不開放新成員。
-- 已註冊者可在各階段使用原暱稱與 PIN 重新進入。
CREATE OR REPLACE FUNCTION public.join_room(p_code text,p_nickname text,p_pin text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE r public.quiz_rooms; p public.quiz_players; v_role text;
BEGIN
 SELECT * INTO r FROM public.quiz_rooms WHERE code=upper(trim(p_code)) FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION '找不到這個房間'; END IF;
 IF char_length(trim(p_nickname)) NOT BETWEEN 1 AND 24 OR p_pin !~ '^[0-9]{4,8}$' THEN
  RAISE EXCEPTION '暱稱或 PIN 格式錯誤';
 END IF;
 SELECT * INTO p FROM public.quiz_players WHERE room_id=r.id AND lower(nickname)=lower(trim(p_nickname));
 IF FOUND THEN
  IF p.pin_hash<>crypt(p_pin,p.pin_hash) THEN RAISE EXCEPTION '這個暱稱已被使用，PIN 不正確'; END IF;
 ELSE
  IF r.status='revealed' THEN RAISE EXCEPTION '答案已公布，不開放新的參加者'; END IF;
  v_role:=CASE WHEN r.status='locked' THEN 'answer_only' ELSE 'author' END;
  INSERT INTO public.quiz_players(room_id,nickname,pin_hash,player_role)
    VALUES(r.id,trim(p_nickname),crypt(p_pin,gen_salt('bf')),v_role) RETURNING * INTO p;
 END IF;
 RETURN jsonb_build_object('room_id',r.id,'player_id',p.id,'room_code',r.code,'is_host',p.is_host,'player_role',p.player_role);
END $$;

CREATE OR REPLACE FUNCTION public.get_room_state(p_room_id uuid,p_player_id uuid DEFAULT null)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE r public.quiz_rooms; p public.quiz_players; qcount integer; submitted_count integer;
BEGIN
 IF p_player_id IS NULL THEN RAISE EXCEPTION '缺少參加者驗證'; END IF;
 p:=public._assert_member(p_room_id,p_player_id);
 SELECT * INTO r FROM public.quiz_rooms WHERE id=p_room_id;
 IF NOT FOUND THEN RAISE EXCEPTION '找不到房間'; END IF;
 SELECT count(*) INTO qcount FROM public.quiz_questions WHERE room_id=p_room_id;
 SELECT count(*) INTO submitted_count FROM public.quiz_submissions WHERE room_id=p_room_id AND submitted;
 RETURN jsonb_build_object('id',r.id,'code',r.code,'status',r.status,'is_host',p.is_host,
  'player_role',p.player_role,'question_count',qcount,'submitted_count',submitted_count);
END $$;
CREATE OR REPLACE FUNCTION public.list_players(p_room_id uuid,p_player_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 PERFORM public._assert_member(p_room_id,p_player_id);
 RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
  'id',p.id,'nickname',p.nickname,'is_host',p.is_host,'player_role',p.player_role,
  'question_count',(SELECT count(*) FROM public.quiz_questions q WHERE q.author_id=p.id),
  'submitted',COALESCE((SELECT s.submitted FROM public.quiz_submissions s WHERE s.room_id=p_room_id AND s.player_id=p.id),false)
 ) ORDER BY p.created_at) FROM public.quiz_players p WHERE p.room_id=p_room_id),'[]'::jsonb);
END $$;

-- 解鎖不可使鎖定後加入的純作答者被迫成為出題者：只要有純作答者就禁止解鎖。
CREATE OR REPLACE FUNCTION public.unlock_room(p_room_id uuid,p_player_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_player public.quiz_players; v_status public.quiz_room_status;
BEGIN
 v_player:=public._assert_member(p_room_id,p_player_id);
 IF NOT v_player.is_host THEN RAISE EXCEPTION '只有主持人可以解鎖'; END IF;
 SELECT status INTO v_status FROM public.quiz_rooms WHERE id=p_room_id FOR UPDATE;
 IF v_status IS DISTINCT FROM 'locked' THEN RAISE EXCEPTION '目前無法解鎖'; END IF;
 IF EXISTS(SELECT 1 FROM public.quiz_submissions WHERE room_id=p_room_id AND submitted) THEN RAISE EXCEPTION '已有人交卷，無法解鎖'; END IF;
 IF EXISTS(SELECT 1 FROM public.quiz_players WHERE room_id=p_room_id AND player_role='answer_only') THEN
  RAISE EXCEPTION '已有純作答者加入，為避免身分與題目不一致，無法解鎖';
 END IF;
 UPDATE public.quiz_rooms SET status='draft' WHERE id=p_room_id;
 RETURN true;
END $$;

CREATE OR REPLACE FUNCTION public.lock_room(p_room_id uuid,p_player_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE p public.quiz_players; r public.quiz_rooms; player_count integer; qbad integer;
BEGIN
 p:=public._assert_member(p_room_id,p_player_id);
 IF NOT p.is_host THEN RAISE EXCEPTION '只有主持人可以鎖定題庫'; END IF;
 SELECT * INTO r FROM public.quiz_rooms WHERE id=p_room_id FOR UPDATE;
 IF r.status <> 'draft' THEN RAISE EXCEPTION '房間不是出題狀態'; END IF;
 SELECT count(*) INTO player_count FROM public.quiz_players WHERE room_id=p_room_id AND player_role='author';
 IF player_count<2 THEN RAISE EXCEPTION '至少需要 2 位出題者'; END IF;
 SELECT count(*) INTO qbad FROM public.quiz_players p2 WHERE p2.room_id=p_room_id AND p2.player_role='author'
 AND (SELECT count(*) FROM public.quiz_questions q WHERE q.room_id=p_room_id AND q.author_id=p2.id) <> 10;
 IF qbad>0 THEN RAISE EXCEPTION '每位出題者需完成 10 題才能鎖定'; END IF;
 UPDATE public.quiz_rooms SET status='locked' WHERE id=p_room_id;
 RETURN true;
END $$;

-- 在已公布答案的房間由主持人建立紙本試卷（額外分數）。
CREATE OR REPLACE FUNCTION public.create_paper_exam(p_room_id uuid,p_player_id uuid,p_title text,p_author_id uuid,p_max_points integer)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_player public.quiz_players; v_id uuid;
BEGIN
 v_player:=public._assert_member(p_room_id,p_player_id);
 IF NOT v_player.is_host THEN RAISE EXCEPTION '只有主持人可以建立紙本試卷'; END IF;
 IF (SELECT status FROM public.quiz_rooms WHERE id=p_room_id) <> 'revealed' THEN RAISE EXCEPTION '公布答案後才能新增紙本試卷'; END IF;
 IF p_title IS NULL OR length(btrim(p_title)) NOT BETWEEN 1 AND 120 OR p_max_points NOT BETWEEN 1 AND 10000 THEN RAISE EXCEPTION '試卷名稱或滿分不合法'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.quiz_players WHERE room_id=p_room_id AND id=p_author_id AND player_role='author') THEN RAISE EXCEPTION '請選擇房間內的出題者'; END IF;
 INSERT INTO public.quiz_paper_exams(room_id,title,author_id,max_points) VALUES(p_room_id,btrim(p_title),p_author_id,p_max_points) RETURNING id INTO v_id;
 RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION public.save_paper_score(p_room_id uuid,p_player_id uuid,p_exam_id uuid,p_target_id uuid,p_points integer)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_player public.quiz_players; v_exam public.quiz_paper_exams;
BEGIN
 v_player:=public._assert_member(p_room_id,p_player_id);
 IF NOT v_player.is_host THEN RAISE EXCEPTION '只有主持人可以登錄紙本成績'; END IF;
 IF (SELECT status FROM public.quiz_rooms WHERE id=p_room_id) <> 'revealed' THEN RAISE EXCEPTION '尚未公布答案'; END IF;
 SELECT * INTO v_exam FROM public.quiz_paper_exams WHERE room_id=p_room_id AND id=p_exam_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION '找不到紙本試卷'; END IF;
 IF p_target_id=v_exam.author_id THEN RAISE EXCEPTION '出題者不能回答自己的紙本試卷'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.quiz_players WHERE room_id=p_room_id AND id=p_target_id) THEN RAISE EXCEPTION '作答者不在此房間'; END IF;
 IF p_points IS NULL OR p_points<0 OR p_points>v_exam.max_points THEN RAISE EXCEPTION '得分超過滿分或不合法'; END IF;
 INSERT INTO public.quiz_paper_scores(room_id,exam_id,player_id,points,updated_by)
 VALUES(p_room_id,p_exam_id,p_target_id,p_points,p_player_id)
 ON CONFLICT(exam_id,player_id) DO UPDATE SET points=EXCLUDED.points,updated_by=EXCLUDED.updated_by,updated_at=now();
 RETURN true;
END $$;

-- 公布答案前鎖住房間列，避免主持人檢查交卷名單時又有新純作答者加入。
CREATE OR REPLACE FUNCTION public.reveal_answers(p_room_id uuid,p_player_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_player public.quiz_players; v_room public.quiz_rooms;
BEGIN
 v_player:=public._assert_member(p_room_id,p_player_id);
 IF NOT v_player.is_host THEN RAISE EXCEPTION '只有主持人可以公布答案'; END IF;
 SELECT * INTO v_room FROM public.quiz_rooms WHERE id=p_room_id FOR UPDATE;
 IF v_room.status <> 'locked' THEN RAISE EXCEPTION '目前不是作答階段'; END IF;
 IF EXISTS(SELECT 1 FROM public.quiz_players pl LEFT JOIN public.quiz_submissions s
   ON s.room_id=pl.room_id AND s.player_id=pl.id
   WHERE pl.room_id=p_room_id AND COALESCE(s.submitted,false)=false) THEN
   RAISE EXCEPTION '仍有人尚未交卷';
 END IF;
 UPDATE public.quiz_rooms SET status='revealed',revealed_at=now() WHERE id=p_room_id;
 RETURN true;
END $$;

-- 分數未登錄時不會產生 quiz_paper_scores 紀錄，與 0 分明確區分。
CREATE OR REPLACE FUNCTION public.get_paper_overview(p_room_id uuid,p_player_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 PERFORM public._assert_member(p_room_id,p_player_id);
 IF (SELECT status FROM public.quiz_rooms WHERE id=p_room_id) <> 'revealed' THEN RAISE EXCEPTION '尚未公布答案'; END IF;
 RETURN COALESCE((
  SELECT jsonb_agg(jsonb_build_object('exam_id',e.id,'title',e.title,'author_id',e.author_id,
   'author_nickname',a.nickname,'max_points',e.max_points,'player_id',p.id,'nickname',p.nickname,
   'points',s.points,'updated_at',s.updated_at) ORDER BY e.created_at,p.created_at)
  FROM public.quiz_paper_exams e
  JOIN public.quiz_players a ON a.id=e.author_id
  JOIN public.quiz_players p ON p.room_id=e.room_id AND p.id<>e.author_id
  LEFT JOIN public.quiz_paper_scores s ON s.room_id=e.room_id AND s.exam_id=e.id AND s.player_id=p.id
  WHERE e.room_id=p_room_id
 ),'[]'::jsonb);
END $$;

-- 統計結果由既有線上榜單及獨立紙本資料計算，不覆寫線上 submissions 或人工評分。
CREATE OR REPLACE FUNCTION public.get_mixed_results(p_room_id uuid,p_player_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 PERFORM public._assert_member(p_room_id,p_player_id);
 IF (SELECT status FROM public.quiz_rooms WHERE id=p_room_id) <> 'revealed' THEN RAISE EXCEPTION '尚未公布答案'; END IF;
 RETURN COALESCE((
  WITH online AS (SELECT x.elem FROM jsonb_array_elements(public.get_results(p_room_id,p_player_id)) AS x(elem)),
  paper AS (
    SELECT e2.player_id, sum(e2.max_points)::integer AS paper_max,
      sum(COALESCE(e2.points,0))::integer AS paper_total,
      bool_or(e2.points IS NULL) AS paper_pending
    FROM (SELECT p.id AS player_id,e.max_points,s.points FROM public.quiz_players p
      JOIN public.quiz_paper_exams e ON e.room_id=p.room_id AND e.author_id<>p.id
      LEFT JOIN public.quiz_paper_scores s ON s.room_id=e.room_id AND s.exam_id=e.id AND s.player_id=p.id
      WHERE p.room_id=p_room_id) e2 GROUP BY e2.player_id
  )
  SELECT jsonb_agg(jsonb_build_object('player_id',p.id,'nickname',p.nickname,
    'online_total',COALESCE((o.elem->>'total')::integer,0),'online_max',COALESCE((o.elem->>'max')::integer,0),
    'paper_total',COALESCE(paper.paper_total,0),'paper_max',COALESCE(paper.paper_max,0),
    'total',COALESCE((o.elem->>'total')::integer,0)+COALESCE(paper.paper_total,0),
    'max',COALESCE((o.elem->>'max')::integer,0)+COALESCE(paper.paper_max,0),
    'pending',COALESCE((o.elem->>'pending')::boolean,false) OR COALESCE(paper.paper_pending,false),
    'paper_pending',COALESCE(paper.paper_pending,false)) ORDER BY p.created_at)
  FROM public.quiz_players p
  JOIN public.quiz_submissions sub ON sub.room_id=p.room_id AND sub.player_id=p.id AND sub.submitted
  LEFT JOIN online o ON o.elem->>'nickname'=p.nickname
  LEFT JOIN paper ON paper.player_id=p.id
  WHERE p.room_id=p_room_id
 ),'[]'::jsonb);
END $$;

REVOKE ALL ON FUNCTION public.create_paper_exam(uuid,uuid,text,uuid,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.save_paper_score(uuid,uuid,uuid,uuid,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_paper_overview(uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_mixed_results(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_paper_exam(uuid,uuid,text,uuid,integer) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.save_paper_score(uuid,uuid,uuid,uuid,integer) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.get_paper_overview(uuid,uuid) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.get_mixed_results(uuid,uuid) TO anon,authenticated;
COMMIT;
NOTIFY pgrst,'reload schema';

-- EOF
