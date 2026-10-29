# v4.4.4 選項圖片讀取診斷版

本版改善選項圖片路徑的格式相容性，並在編輯時區分「未回傳路徑」與「網址載入失敗」。

- 先更新 GitHub 的 `app.js`；不需要執行新的資料庫升級 SQL。
- 執行 `supabase/diagnose_option_images.sql`（唯讀），確認每個選項的 `has_image_for_abcd`。
- 若為 false：圖片路徑沒有存入資料庫，單靠前端無法恢復，請重新上傳並確認儲存後再次查詢。
- 若為 true 但圖片載入失敗：在瀏覽器開發人員工具查看 Storage 的 403/404 請求及正確 bucket 設定。

此版通過前端 ES Module 語法檢查，未進行連線 Supabase 的實際驗收。
