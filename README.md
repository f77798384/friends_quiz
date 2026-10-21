# 朋友出題大會 v1（測試版）

手機優先的聚餐測驗網站：每人 10 題、每題可設定配分、選擇／是非／填空／簡答／圖片題、全部交卷後由主持人公布答案。前端使用 HTML/CSS/JavaScript，Supabase 儲存資料，GitHub Pages 部署。

## 重要安全說明

這是**私人聚餐的第一版原型**，使用房間代碼、暱稱與 PIN 的簡化登入方式。資料表的直接存取已關閉，主要操作透過資料庫 RPC；但瀏覽器端的 player ID 並不是強身分憑證，因此這個版本不適合公開大型活動或存放敏感資料。若要抵禦惡意參加者，下一版應改成 Supabase Auth 或 Edge Function 簽發的簽名工作階段、登入限速與更嚴格的權限驗證。

## A. 建立 Supabase

1. 到 https://supabase.com 建立專案。
2. 開啟 **SQL Editor**，將 `supabase/schema.sql` 全文貼上並執行。
3. 到 **Storage** 建立 bucket，名稱填 `quiz-images`，選擇 **Private**。
4. 第一版請先測試文字題。圖片題的欄位與資料庫欄位已預留，但安全的圖片上傳／顯示尚未啟用。
5. 到 Project Settings → API，複製 Project URL 與 anon/public key。

### 為什麼圖片上傳先保留？

Supabase Storage 的 private bucket 需要可靠的使用者身分或伺服器簽發的短期簽名 URL。這個原型用暱稱＋PIN 建立簡化的參加者識別，還沒有 Edge Function 簽發工作階段，因此不應直接開放匿名上傳或把 private bucket 變成任意可讀。下一個安全迭代應加入 Supabase Edge Function／Auth，再啟用圖片上傳。

## B. 設定前端

1. 編輯 `config.js`：
   - `SUPABASE_URL`：貼上 Project URL。
   - `SUPABASE_ANON_KEY`：貼上 anon/public key。
2. 絕對不要貼 `service_role` key。
3. 本機測試時，建議使用 VS Code Live Server 或任何靜態 HTTP server，不要直接用 `file://` 開啟 `index.html`。

## C. 部署 GitHub Pages

1. 建立一個新的 GitHub repository。
2. 上傳 `index.html`、`style.css`、`app.js`、`config.js` 與 `README.md`。
3. Repository → Settings → Pages → Deploy from a branch → `main` / `/root`。
4. 等待 GitHub Pages 發布，開啟它提供的 HTTPS 網址。
5. 用兩台手機測試建立房間與加入房間。

## D. 第一輪測試清單

- [ ] 建立房間，記下代碼。
- [ ] 另一個瀏覽器以不同暱稱加入。
- [ ] 每人建立 10 題。
- [ ] 主持人鎖定題庫。
- [ ] 參加者作答並交卷。
- [ ] 所有人交卷後主持人公布答案。
- [ ] 檢查客觀題分數與簡答題人工評分。
- [ ] 檢查公布前是否無法讀取正解。
- [ ] 檢查手機重新整理後能否重新加入同一房間。
- [ ] 本版圖片題的圖片上傳／顯示尚未啟用，先以文字題完成整體流程測試。

## 已知限制／下一步

這是起始專案，不是已經連到你的 Supabase 的上線服務。上線前需完成設定、測試與安全強化。圖片上傳／讀取需要 private Storage 的安全簽名 URL 或 Edge Function；簡化 PIN 登入也應改成可信任的 server-side session。若要公開正式使用，先完成這兩項再開放使用者。
