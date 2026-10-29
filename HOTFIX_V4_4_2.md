# v4.4.2 修復說明

修正 `Cannot access 'answerDraft' before initialization`：原本 `answerDraft` 在頁面初始化與恢復房間之後才宣告；重新整理或執行 `refreshAll` 時，`renderPlay` 可能先讀取變數而引發 TDZ 錯誤。現已把 `answerDraft` 宣告移到最前面的全域狀態區。

只需更新 `app.js`；**不需執行任何 Supabase SQL**。

檢查：Node JavaScript 語法與 ES Module 語法檢查通過，並確認宣告早於恢復房間的啟動呼叫。尚未在使用者的 Supabase 中進行實際瀏覽器端對端測試。
