-- 唯讀查詢，確認選項圖片路徑是否真的保存在資料庫。
-- 請在 Supabase SQL Editor 執行；只分享 has_image 欄位即可，避免洩漏圖片路徑。
SELECT q.id,
       q.type,
       jsonb_typeof(q.option_image_paths) AS paths_type,
       jsonb_array_length(CASE WHEN jsonb_typeof(q.option_image_paths)='array'
                         THEN q.option_image_paths ELSE '[]'::jsonb END) AS paths_count,
       ARRAY(SELECT (q.option_image_paths->>i) IS NOT NULL
             FROM generate_series(0,3) AS i) AS has_image_for_abcd
FROM public.quiz_questions q
WHERE q.type='single'
ORDER BY q.created_at DESC LIMIT 20;
