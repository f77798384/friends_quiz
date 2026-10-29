# Friends Quiz v4.1 更新說明

1. 備份 Supabase 資料庫。此檔案假設先前 v3、v4 SQL 已成功執行。
2. 上傳本 ZIP 解壓縮後的前端檔案到 GitHub Pages。
3. Supabase SQL Editor 執行 `supabase/upgrade_v4_1.sql`（不要重跑 schema.sql）。
4. 等待 PostgREST schema cache 更新，強制重新整理網頁再建立全新測試房間。

修復：`save_question` 11 參數函式簽章與 schema cache 不一致；新增題目文字可為空但必須有題幹圖片；選擇題選項可只有圖片。純圖片選項使用內部唯一答案值 `__FQ_IMAGE_ONLY_0__` 至 `_3__`，畫面只顯示照片。

注意：無法連線至使用者 Supabase 做端對端測試；已執行 JavaScript 語法及靜態一致性檢查。若 SQL Editor 報錯，請勿反覆執行，請回報完整錯誤內容。
