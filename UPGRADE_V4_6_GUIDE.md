# Friends Quiz v4.6 升級指南

適用 **Supabase 已更新至 v4.5.5** 的環境。

1. **先備份資料庫**，尤其 `quiz_players`、`quiz_submissions`、`quiz_questions`。
2. 將 `index.html`、`app.js`、`README.md` 更新到 GitHub Pages；`config.js` 保持原本正確設定。
3. 在 Supabase SQL Editor 執行 `supabase/upgrade_v4_6.sql`。
4. SQL 成功後強制重新整理網頁，使用**新房間**依 README 的 v4.6 快速驗收清單測試。
5. 若 SQL 失敗，**先停止**，保留錯誤訊息；不要重新執行 `schema.sql`，也不要刪除現有資料表。

此 migration 建立 `player_role`、紙本試卷與成績表，並更新加入、鎖定、解鎖、房間資訊 RPC；新增紙本管理與整合榜單 RPC。不會清空原有題目、作答或成績。

已知限制：目前沒有刪除紙本試卷或清除已登錄紙本分數的操作；未登錄分數與 0 分有意區分。因現有 PIN / player ID 為輕量身分模型，正式公開活動仍需加強驗證與權限。
