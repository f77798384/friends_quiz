# Friends Quiz v4.4.3 — 重新編輯時圖片選項空白修正

## 根因
編輯資料取自 `my_questions()`，不是 `list_questions()`。如果 Supabase 裡的 `my_questions()` 還是舊版，會漏掉 `option_image_paths`，導致圖片選項在重新編輯時空白。

## 安裝
1. 備份 Supabase 資料庫。
2. GitHub 部署此 ZIP 的 `app.js`（其餘前端檔案不變）。
3. Supabase SQL Editor 只執行 `supabase/upgrade_v4_4_3.sql`，不要重跑 `schema.sql`。
4. 強制重新整理頁面，新建測試題：四個純圖片選項，儲存後重開編輯，應顯示四張圖片。
5. 換圖時只上傳想替換的那一張，再儲存、重新編輯檢查另外三張仍在。

## 重要限制
若原本資料庫中 `option_image_paths` 已是空陣列，代表圖片路徑可能沒被儲存，更新讀取函式不能恢復遺失的路徑。可在 SQL Editor 查核欄位值，若是空的則需重新上傳圖片。

## 檢查
已完成 JavaScript ES Module 語法檢查、SQL/前端欄位對應靜態檢查與 ZIP 完整性檢查。未連接使用者 Supabase 進行端對端實測。
