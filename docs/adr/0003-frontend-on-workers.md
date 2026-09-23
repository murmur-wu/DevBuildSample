# ADR 0003：前端部署在 Cloudflare Workers，經 Worker 代轉呼叫後端

- 狀態：Accepted
- 日期：2026-09-23

## 背景

需要一個前端頁面呼叫後端 API（Node 版與 .NET 版）並呈現資料，部署在 Cloudflare。後端對外網址為 `https://api-staging.heitang.info/node/...`、`/dotnet/...`，目前沒有處理 CORS。

## 決策

1. **用 Workers Static Assets，不用 Pages**：Cloudflare 官方文件建議新專案改用 Workers；Pages 仍可用，但新功能集中在 Workers。
2. **同一個 Worker 提供靜態頁面與 API 代轉**：`wrangler.jsonc` 設 `run_worker_first: ["/api/*"]`，只有 `/api/*` 進 Worker，其他路徑直接回 `public/` 的靜態檔案。`/api/node/*`、`/api/dotnet/*` 轉到 `vars` 設定的 `NODE_API`、`DOTNET_API`，並把後端的 `Location` header 改寫成 `/api/<backend>/...`。
3. **前端為純 HTML/CSS/JS**：沒有 build 步驟，範例專案保持簡單。可切換 Node / .NET 後端，直接比較兩者。
4. **部署走 GitHub Actions**：`cd-web.yml` 以 `cloudflare/wrangler-action@v4` 部署，完成後對部署網址跑兩個後端的 smoke test（瀏覽器 → Worker → Tunnel → 後端整條路）。`ci-web.yml` 在 PR 時用 `wrangler dev` 代轉到 CI 內啟動的兩個後端，跑同一支 smoke test。

## 考慮過的替代方案

- **後端加 CORS**：前端直接呼叫 api-staging。需要兩版後端都處理 CORS header 與 `OPTIONS` 預檢，並擴充 smoke test；後端網址變動時前端要重新部署。
- **Cloudflare 的 Git 整合（Workers Builds）**：不需要在 GitHub 放 token，但部署與驗證流程會分散在 Cloudflare dashboard，和其他 CI/CD 不一致。

## 後果

- 優點：無 CORS、後端不用改；後端網址只在 Worker 設定一處；前端與 API 同網域，之後要加登入 cookie 也比較單純。
- 代價：每個 API 請求多經過一次 Worker（在 Cloudflare 邊緣，延遲很小，免費方案每日 10 萬次請求）；需要在 GitHub 保存 Cloudflare API token。
