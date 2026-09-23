# ADR 0002：.NET 10 版後端與 Node 版並存

- 狀態：Accepted
- 日期：2026-09-23

## 背景

後端要評估改用 .NET 10。希望在不影響現有 Node 版的前提下，讓 .NET 版也能獨立測試、獨立部署到同一台 staging 主機，並能直接比較兩者行為。

## 決策

1. **同一份 API 合約、兩個實作**：.NET 版（`apps/api-dotnet/`，ASP.NET Core Minimal API + Npgsql）完全照 Node 版的路由、欄位（snake_case）、狀態碼與錯誤訊息實作。`scripts/smoke-test.sh` 是兩者共用的驗收標準。
2. **執行環境完全隔離**：各自的 compose 檔與 compose project（`myapp` / `myapp-dotnet`），各自的 PostgreSQL 容器與 volume。部署、重建、清資料互不影響。代價是多一個 Postgres 容器（約 50–100MB 記憶體）。
3. **Port 與對外網址**：Node 3000、.NET 3001（容器內 8080），都只綁 127.0.0.1。對外共用同一個網址 `api-staging.heitang.info`，由 Cloudflare Tunnel 依路徑前綴分流：`/node/...` → Node、`/dotnet/...` → .NET，其他路徑 404。cloudflared 轉送時不會去掉前綴，因此兩版都以環境變數 `PATH_BASE` 自行去掉（.NET 用 `UsePathBase`，Node 手寫同樣的行為）；沒帶前綴的請求照常處理，本機與 healthcheck 不受影響。
   - 考慮過的替代方案：兩個子網域（程式不用改、隔離較好）、主機上加反向代理去掉前綴（多一個服務要維護）。本專案為練習用範例，選擇共用網址以演練路徑分流。
4. **CI/CD 依路徑分流**：`ci-node.yml` / `ci-dotnet.yml`、`cd-node.yml` / `cd-dotnet.yml` 以 `paths` 過濾，只有改到自己的檔案才執行。build + deploy 邏輯抽成 reusable workflow `_build-deploy.yml`，兩個 CD 只傳入 image 名稱、build context、compose 檔、project、port。
5. **.NET 另有單元測試**：`tests/Api.Tests`（xUnit）測輸入驗證；CI 在 `mcr.microsoft.com/dotnet/sdk:10.0` 容器中執行 `dotnet test`，本機不需安裝 SDK。
6. **機敏設定共用** `/srv/myapp/.env`：兩個 DB 容器是獨立初始化的，共用帳密不會互相影響。

## 後果

- 優點：可以並排比較兩版；任一版出問題不影響另一版；之後要淘汰其中一版，只需刪掉它的資料夾、compose 檔、兩個 workflow 與 tunnel hostname。
- 代價：API 行為要在兩處維護，改一版必須同步改另一版（smoke test 會擋住不一致）；主機多跑一組 api + db。
- 已知可接受的差異：時間戳精度（Node 毫秒、.NET 微秒）、`GET /` 的 `name`。
