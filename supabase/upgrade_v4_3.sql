-- Friends Quiz: 修復 quiz_questions 缺少 option_image_paths 欄位
-- 適用已安裝 v4.2 save_question、但尚未建立此欄位的資料庫。
-- 非破壞性操作，不刪除題目或既有資料。
BEGIN;
ALTER TABLE public.quiz_questions
  ADD COLUMN IF NOT EXISTS option_image_paths jsonb NOT NULL DEFAULT '[]'::jsonb;
COMMIT;
NOTIFY pgrst, 'reload schema';

-- 驗證欄位已存在
SELECT column_name, data_type, column_default
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'quiz_questions'
  AND column_name = 'option_image_paths';
