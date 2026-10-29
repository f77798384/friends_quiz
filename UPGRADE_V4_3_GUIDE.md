# v4.3 缺欄位修正

已安裝 v4.2 的 Supabase 請先備份，再只執行 `supabase/upgrade_v4_3.sql`。這個增量更新只新增 `option_image_paths` 欄位。不要重新執行舊版 v3、v4.1 或 schema.sql，否則可能覆蓋現有函式。

執行後確認查詢回傳一列 `option_image_paths`，再測試新增純圖片選項。若後續出現其他函式不存在，需另行核對 v3 的完整遷移狀態。
