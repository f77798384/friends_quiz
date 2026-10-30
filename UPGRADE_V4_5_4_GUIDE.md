# v4.5.4 啟動錯誤修正

`app.js:306` 的 `unlockBtn` 不存在時，原本直接呼叫 `addEventListener` 會阻止整份前端啟動。新版採安全綁定，避免舊 HTML 導致整站失效。

**請同時更新 `index.html` 和 `app.js`**：`index.html` 必須包含 `id="unlockBtn"`。只更新 app.js 雖可避免崩潰，但無法顯示解鎖按鈕。

無須更新 Supabase。本次沒有變更資料表與 SQL。

上傳後清除網站快取並重新整理。若仍有問題，請檢查 Network 頁面載入的 app.js 和 index.html 是否為相同版本。

檢查：Node JavaScript 語法通過，已掃描靜態 HTML 元素與頂層事件綁定；未在正式站完成瀏覽器端對端測試。
