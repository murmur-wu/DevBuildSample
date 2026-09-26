# ADR 0008：不公開 Swagger UI，後端以 Cloudflare Access 保護

- 狀態：Accepted
- 日期：2026-09-26

## 背景

repo 準備公開，Demo 只打算公開前端（待辦清單）。原本：

- 前端網站的 `/docs/` 提供 Swagger UI，「Try it out」可直接對 staging 後端寫入資料；`/openapi.yaml` 也是公開的靜態檔。
- 後端 `api-staging.heitang.info/<版本>/...` 經 Cloudflare Tunnel 直接對外，任何人都能打。

前端本身會經由 Worker 的 `/api/<版本>/` 代轉讀寫資料，所以後端不能完全斷開，只能讓「前端 Worker 以外的人」進不來。

## 決策

1. **移除 Swagger UI**：刪除 `apps/web/public/docs/`，`openapi.yaml` 移到 `apps/web/openapi.yaml`（不在 `public/`，不會被當成靜態檔公開），仍作為各版的契約與 CI 的 lint 對象。`ci-web.yml` 檢查 `/docs/` 與 `/openapi.yaml` 回 404。
2. **後端以 Cloudflare Access 保護**：對 `api-staging.heitang.info` 整個 hostname 建立 Self-hosted 應用程式，policy 為 Service Auth（service token `devbuildsample-web`），另可加上擁有者 email 的 Allow。
3. **前端 Worker 帶 service token**：`worker.js` 在代轉時加上 `CF-Access-Client-Id`、`CF-Access-Client-Secret`（Worker secrets，設定在 dashboard，不進 git）。被 Access 擋下（30x 轉到 `*.cloudflareaccess.com`、401、403）時回 502 `backend access denied` 並記錄 log，不把登入頁轉址交給瀏覽器。
4. **工具支援 token**：`smoke-test.sh` 與 `setup-tunnel.sh` 在設定了 `CF_ACCESS_CLIENT_ID`、`CF_ACCESS_CLIENT_SECRET` 時會帶上 header；`setup-tunnel.sh` 沒有 token 時把「被 Access 擋下」視為 tunnel 已連通。

考慮過的替代方案：

- **只在 tunnel 關掉對外路由，改由 Worker 直連**：Worker 無法連到 buildserver 的 127.0.0.1，仍需要一條對外的路徑。
- **後端自己檢查共用密鑰 header**：六個後端都要實作，且密鑰要放進 `/srv/myapp/.env` 與 compose；Access 在 Cloudflare 邊緣就擋掉，後端不用改。
- **Cloudflare WAF 規則只允許帶特定 header 的請求**：可行，但 Access 內建 token 管理（到期、輪替）與擁有者用 email 登入的方式。

## 後果

- 直接打 `api-staging.heitang.info` 會被擋；前端照常可用。CD 的 `/health` 驗證與 smoke test 打 buildserver 本機，不受影響。
- 多了一組要管理的 service token（有到期日）；到期或外洩時要重新產生並更新 Worker secrets。
- 上線順序有依賴：先設定 Worker secrets 並部署新版 Worker，最後才建立 Access 應用程式，否則前端會暫時回 502。
- Worker 的 `/api/<版本>/` 代轉仍是公開的，任何人都能經由前端網址讀寫 staging 資料；要防濫用需另設 rate limiting。
- 失去線上的互動式 API 文件；要看規格請讀 repo 裡的 `apps/web/openapi.yaml`。
