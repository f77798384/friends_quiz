-- Friends Quiz v4.5.5: 排行榜排除自己題目，支援依出題者檢視
-- 不改動房間、題目、交卷或人工評分資料。
BEGIN;
CREATE OR REPLACE FUNCTION public.get_results(p_room_id uuid,p_player_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 PERFORM public._assert_member(p_room_id,p_player_id);
 IF (SELECT status FROM public.quiz_rooms WHERE id=p_room_id) <> 'revealed' THEN RAISE EXCEPTION '尚未公布答案'; END IF;
 RETURN COALESCE((
 WITH scored AS (
 SELECT s.player_id, q.author_id, sum(CASE WHEN q.type='short' THEN coalesce(g.awarded_points,0)
 WHEN q.type='boolean' AND (CASE WHEN lower(trim(s.responses->>(q.id::text))) IN ('是','true') THEN '是' WHEN lower(trim(s.responses->>(q.id::text))) IN ('否','false') THEN '否' ELSE '' END)=(CASE WHEN lower(trim(q.correct_answer)) IN ('是','true') THEN '是' ELSE '否' END) THEN q.points
 WHEN q.type='single' AND lower(trim(s.responses->>(q.id::text)))=lower(trim(q.correct_answer)) THEN q.points
 WHEN q.type='fill' AND EXISTS(SELECT 1 FROM unnest(string_to_array(q.correct_answer,'|')) a WHERE lower(trim(a))=lower(trim(s.responses->>(q.id::text)))) THEN q.points
 ELSE 0 END)::integer AS total,
 sum(q.points)::integer AS max,
 coalesce(bool_or(q.type='short' AND g.question_id IS NULL),false) AS pending
 FROM public.quiz_submissions s
 JOIN public.quiz_questions q ON q.room_id=s.room_id AND q.author_id<>s.player_id
 LEFT JOIN public.quiz_manual_grades g ON g.room_id=s.room_id AND g.player_id=s.player_id AND g.question_id=q.id
 WHERE s.room_id=p_room_id AND s.submitted
 GROUP BY s.player_id,q.author_id
)
 SELECT jsonb_agg(jsonb_build_object('nickname',p.nickname,'total',coalesce(t.total,0),
 'max',coalesce(t.max,0),'pending',coalesce(t.pending,false)) ORDER BY p.created_at)
 FROM public.quiz_players p
 LEFT JOIN (SELECT player_id,sum(total) AS total,sum(max) AS max,bool_or(pending) AS pending FROM scored GROUP BY player_id) t ON t.player_id=p.id
 WHERE p.room_id=p_room_id AND EXISTS(SELECT 1 FROM public.quiz_submissions s WHERE s.room_id=p_room_id AND s.player_id=p.id AND s.submitted)
 ),'[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION public.get_score_by_author(p_room_id uuid,p_player_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 PERFORM public._assert_member(p_room_id,p_player_id);
 IF (SELECT status FROM public.quiz_rooms WHERE id=p_room_id) <> 'revealed' THEN RAISE EXCEPTION '尚未公布答案'; END IF;
 RETURN COALESCE((
 WITH scored AS (
 SELECT s.player_id, q.author_id, sum(CASE WHEN q.type='short' THEN coalesce(g.awarded_points,0)
 WHEN q.type='boolean' AND (CASE WHEN lower(trim(s.responses->>(q.id::text))) IN ('是','true') THEN '是' WHEN lower(trim(s.responses->>(q.id::text))) IN ('否','false') THEN '否' ELSE '' END)=(CASE WHEN lower(trim(q.correct_answer)) IN ('是','true') THEN '是' ELSE '否' END) THEN q.points
 WHEN q.type='single' AND lower(trim(s.responses->>(q.id::text)))=lower(trim(q.correct_answer)) THEN q.points
 WHEN q.type='fill' AND EXISTS(SELECT 1 FROM unnest(string_to_array(q.correct_answer,'|')) a WHERE lower(trim(a))=lower(trim(s.responses->>(q.id::text)))) THEN q.points
 ELSE 0 END)::integer AS total,
 sum(q.points)::integer AS max,
 coalesce(bool_or(q.type='short' AND g.question_id IS NULL),false) AS pending
 FROM public.quiz_submissions s
 JOIN public.quiz_questions q ON q.room_id=s.room_id AND q.author_id<>s.player_id
 LEFT JOIN public.quiz_manual_grades g ON g.room_id=s.room_id AND g.player_id=s.player_id AND g.question_id=q.id
 WHERE s.room_id=p_room_id AND s.submitted
 GROUP BY s.player_id,q.author_id
)
 SELECT jsonb_agg(jsonb_build_object('author_id',t.author_id,'player_id',t.player_id,
 'nickname',p.nickname,'total',t.total,'max',t.max,'pending',t.pending)
 ORDER BY a.created_at,p.created_at)
 FROM scored t
 JOIN public.quiz_players p ON p.id=t.player_id AND p.room_id=p_room_id
 JOIN public.quiz_players a ON a.id=t.author_id AND a.room_id=p_room_id
 ),'[]'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.get_results(uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_score_by_author(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_results(uuid,uuid) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.get_score_by_author(uuid,uuid) TO anon,authenticated;
COMMIT;
NOTIFY pgrst,'reload schema';
