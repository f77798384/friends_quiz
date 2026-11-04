-- v4.6.1：紙本只由純作答者出題，固定暱稱及 100 分，主持人可刪除
-- 先備份資料庫；本升級不會自動刪除既有紙本試卷或成績。
BEGIN;

-- 舊的五參數函式不再對匿名使用者提供執行權，避免繞過新版限制。
REVOKE ALL ON FUNCTION public.create_paper_exam(uuid,uuid,text,uuid,integer) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.create_paper_exam(
 p_room_id uuid,p_player_id uuid,p_author_id uuid
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_host public.quiz_players; v_author public.quiz_players; v_id uuid;
BEGIN
 v_host:=public._assert_member(p_room_id,p_player_id);
 IF NOT v_host.is_host THEN RAISE EXCEPTION '只有主持人可以新增紙本試卷'; END IF;
 -- 鎖住房間列，讓同一出題者的重複建立在伺服器端依序進行。
 PERFORM 1 FROM public.quiz_rooms WHERE id=p_room_id AND status='revealed' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION '公布答案後才能新增紙本試卷'; END IF;
 SELECT * INTO v_author FROM public.quiz_players WHERE room_id=p_room_id AND id=p_author_id;
 IF NOT FOUND OR v_author.player_role <> 'answer_only' THEN
   RAISE EXCEPTION '只能選擇鎖定後加入的純作答者作為紙本出題者';
 END IF;
 IF EXISTS(SELECT 1 FROM public.quiz_questions WHERE room_id=p_room_id AND author_id=p_author_id) THEN
   RAISE EXCEPTION '這位玩家已有線上出題紀錄，不能建立紙本試卷';
 END IF;
 IF EXISTS(SELECT 1 FROM public.quiz_paper_exams WHERE room_id=p_room_id AND author_id=p_author_id) THEN
   RAISE EXCEPTION '這位出題者已建立紙本試卷';
 END IF;
 INSERT INTO public.quiz_paper_exams(room_id,author_id,title,max_points)
 VALUES(p_room_id,p_author_id,v_author.nickname,100) RETURNING id INTO v_id;
 RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.create_paper_exam(uuid,uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_paper_exam(uuid,uuid,uuid) TO anon,authenticated;

CREATE OR REPLACE FUNCTION public.delete_paper_exam(
 p_room_id uuid,p_player_id uuid,p_exam_id uuid
) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_host public.quiz_players; v_deleted uuid;
BEGIN
 v_host:=public._assert_member(p_room_id,p_player_id);
 IF NOT v_host.is_host THEN RAISE EXCEPTION '只有主持人可以刪除紙本試卷'; END IF;
 PERFORM 1 FROM public.quiz_rooms WHERE id=p_room_id AND status='revealed' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION '只能在公布答案後管理紙本試卷'; END IF;
 DELETE FROM public.quiz_paper_exams WHERE id=p_exam_id AND room_id=p_room_id RETURNING id INTO v_deleted;
 IF v_deleted IS NULL THEN RAISE EXCEPTION '找不到這份紙本試卷'; END IF;
 -- quiz_paper_scores 的 FK 設有 ON DELETE CASCADE，一併清除關聯分數。
 RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.delete_paper_exam(uuid,uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_paper_exam(uuid,uuid,uuid) TO anon,authenticated;
COMMIT;
NOTIFY pgrst,'reload schema';
