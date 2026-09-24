# CLAUDE.md

## 語言

- 對話回覆一律使用**繁體中文**。
- git commit 訊息（標題與內文）、PR 標題與描述一律使用**繁體中文**。程式碼中的識別字維持英文；註解可用繁體中文。

## 專案概觀

最小範例後端，同一套 API 有兩種實作，各自獨立測試、獨立部署，搭配 pull-based CD。架構決策見 `docs/adr/0001-pull-based-deploy.md`。

| | Node 版 | .NET 版 |
|---|---|---|
| 原始碼 | `apps/api/`（Node 22，純 node:http + pg） | `apps/api-dotnet/`（.NET 10 Minimal API + Npgsql） |
| compose / project | `deploy/docker-compose.yml` / `myapp` | `deploy/docker-compose.dotnet.yml` / `myapp-dotnet` |
| 本機 port（容器內） | 3000（3000） | 3001（8080） |
| GHCR image | `ghcr.io/murmur-wu/devbuildsample/api` | `ghcr.io/murmur-wu/devbuildsample/api-dotnet` |
| 對外網址（PATH_BASE） | `https://api-staging.heitang.info/node/...`（`/node`） | `https://api-staging.heitang.info/dotnet/...`（`/dotnet`） |
| CI / CD | `ci-node.yml` / `cd-node.yml` | `ci-dotnet.yml` / `cd-dotnet.yml` |

前端 `apps/web/` 部署在 Cloudflare Workers（Static Assets + 一支代轉 Worker，`devbuildsample-web`）：`/api/node/*`、`/api/dotnet/*` 由 `src/worker.js` 代轉到 `NODE_API`、`DOTNET_API`（`wrangler.jsonc` 的 `vars`），其他路徑回 `public/` 的靜態檔案。CI：`ci-web.yml`（GitHub Actions）；CD：Cloudflare **Workers Builds**（Git 整合，root directory `apps/web`、watch paths `apps/web/*`，設定在 Cloudflare dashboard，不在 repo 裡）。

**兩版 API 必須保持一致**（欄位 snake_case、狀態碼、錯誤訊息），契約寫在 `apps/web/public/openapi.yaml`（OpenAPI 3.1，Swagger UI 在前端的 `/docs/`），共用 `scripts/smoke-test.sh` 驗收。改其中一版的行為時，另一版也要同步修改，並在 smoke test 補上檢查。已知且可接受的差異：時間戳精度（Node 毫秒、.NET 微秒）、`GET /` 的 `name`（`api` / `api-dotnet`）。

```
apps/api/src/server.js                    Node 版 API
apps/api/Dockerfile                       node:22-alpine，npm ci，內建 HEALTHCHECK
apps/api-dotnet/src/Api/Program.cs        .NET 版路由、JSON 讀取與錯誤處理
apps/api-dotnet/src/Api/ItemInput.cs      .NET 版輸入驗證（單元測試對象）
apps/api-dotnet/src/Api/ItemStore.cs      .NET 版 SQL（與 Node 版相同）
apps/api-dotnet/tests/Api.Tests/          xUnit 單元測試
apps/api-dotnet/Dockerfile                sdk:10.0 編譯 → aspnet:10.0-alpine 執行
deploy/docker-compose.yml                 Node 版部署用
deploy/docker-compose.dotnet.yml          .NET 版部署用（獨立的 DB 容器與 volume）
deploy/docker-compose*.local.yml          本地 override：改為原始碼 build
deploy/.env.example                       機敏設定範本（兩版共用 /srv/myapp/.env）
scripts/local-up.sh                       本地一鍵啟動：[node|dotnet] [up|down|clean|logs]
scripts/smoke-test.sh [URL]               端到端測試（20 項），兩版共用；URL 可帶路徑前綴
scripts/vm/setup-tunnel.sh      部署主機：Cloudflare Tunnel（一般使用者執行）
scripts/vm/setup-firewall.sh    部署主機：ufw，預設保留 SSH（sudo 執行）
scripts/vm/setup-maintenance.sh 部署主機：Docker 清理、swap、自動安全更新（sudo 執行）
.github/workflows/ci-node.yml             Node：smoke test
.github/workflows/ci-dotnet.yml           .NET：dotnet test + smoke test
.github/workflows/cd-node.yml             Node：呼叫 _build-deploy.yml
.github/workflows/cd-dotnet.yml           .NET：呼叫 _build-deploy.yml
.github/workflows/_build-deploy.yml       共用：雲端 build → GHCR → self-hosted runner 部署 → /health → smoke test
.github/workflows/ci-web.yml              前端：wrangler dev 代轉到本機兩個後端，跑 smoke test
.github/actionlint.yaml                   宣告自訂 runner label（staging），供 actionlint 檢查
.github/dependabot.yml                    每週檢查基底 image（Dockerfile、compose）與 GitHub Actions 更新，開 PR；不提議主版本升級
apps/web/public/                          前端靜態頁面（純 HTML/CSS/JS，無 build 步驟）
apps/web/src/worker.js                    API 代轉，改寫 Location header
apps/web/wrangler.jsonc                   Worker 設定：run_worker_first ["/api/*"]、vars
apps/web/public/openapi.yaml              API 規格（兩版共同契約）；servers 為 /api/node、/api/dotnet（經 Worker 代轉）
apps/web/public/docs/                     Swagger UI（jsDelivr 載入 swagger-ui-dist，固定版本 + SRI）
apps/web/redocly.yaml                     OpenAPI 檢查規則（npm run lint:openapi）
```

API：`GET /health`（會查 DB，失敗回 503）、`GET /`、`/items` CRUD（GET 列表、POST、GET/PUT/DELETE `/items/:id`）。`items` 資料表在啟動時以 `CREATE TABLE IF NOT EXISTS` 建立，DB 未就緒會重試。

## 常用指令

```bash
./scripts/local-up.sh [node|dotnet]         # build + 啟動 + 等 healthy + 打 /health（預設 node）
./scripts/smoke-test.sh [URL]               # 預設 http://127.0.0.1:3000；.NET 版用 http://127.0.0.1:3001
./scripts/local-up.sh [node|dotnet] down    # 停止（保留資料）
./scripts/local-up.sh [node|dotnet] clean   # 停止並刪除 DB volume
./scripts/local-up.sh [node|dotnet] logs    # 容器 log
docker run --rm -v "$PWD/apps/api-dotnet:/src" -w /src mcr.microsoft.com/dotnet/sdk:10.0 dotnet test   # .NET 單元測試
actionlint                                  # 改 workflow 後檢查（設定在 .github/actionlint.yaml）
cd apps/web && cp .dev.vars.example .dev.vars && npm run dev   # 前端本機開發（先啟動兩個後端），http://127.0.0.1:8787
./scripts/smoke-test.sh http://127.0.0.1:8787/api/node          # 經 Worker 代轉跑 smoke test
cd apps/web && npm run lint:openapi                              # 檢查 OpenAPI 規格
sudo docker logs -f myapp-api-1                                  # staging 上看 Node 的請求紀錄（.NET：myapp-dotnet-api-1）
sudo docker exec myapp-db-1 psql -U postgres -d app -c 'SELECT * FROM items;'   # 直接查資料庫
```

修改 API 後，送出前至少對改到的那一版跑一次 `local-up.sh` + `smoke-test.sh`（.NET 版另跑 `dotnet test`）。新增 endpoint 或改變行為時：兩版都要實作、同步更新 `openapi.yaml`（並跑 `npm run lint:openapi`）、在 `smoke-test.sh` 補上檢查，並更新 README 的 API 表格。

## 部署環境（staging）

- runner：`cd-vm`，label `staging`，跑在主機 `buildserver` 上，以 `deploy` 使用者執行（systemd 服務 `actions.runner.murmur-wu-DevBuildSample.cd-vm`）。
- compose project 名稱：Node `myapp`、.NET `myapp-dotnet`（本地測試用 `myapp-local`、`myapp-dotnet-local`）。兩者各有自己的 DB 容器與 volume，互不影響。
- CI/CD 依路徑觸發（見各 workflow 的 `paths`）：改 `apps/api-dotnet/` 只跑 .NET 的 CI/CD；改 `scripts/smoke-test.sh` 或 `_build-deploy.yml` 會兩邊都跑。兩個 CD 的 deploy 都在同一個 runner 上，會排隊依序執行。
- 機敏設定：VM 上的 `/srv/myapp/.env`（owner `deploy`、`chmod 600`），**永不進 git**。必須包含 `POSTGRES_PASSWORD`。
- 服務只綁 127.0.0.1，對外走 Cloudflare Tunnel `myapp-staging`，同一個網址用路徑分流：`https://api-staging.heitang.info/node/...` → `127.0.0.1:3000`、`/dotnet/...` → `127.0.0.1:3001`，其他路徑 404。設定在 `/etc/cloudflared/config.yml`，憑證在 `/etc/cloudflared/<tunnel-id>.json`（root、600），systemd 服務 `cloudflared`。
- 容器 log 上限在兩個 compose 檔的 `x-logging`；新增服務時要加上 `logging: *logging`。
- image tag 使用 git SHA；回滾：Actions → CD (Node) 或 CD (.NET) → Run workflow，`image_tag` 填舊 SHA（會跳過 build）。
- CD 部署後依序跑 `/health` 驗證與 smoke test；`/health` 回傳的 `version` 應等於部署的 commit SHA。
- CD 的時間上限：`Pull images` 20 分鐘、`Deploy`（`up --wait --wait-timeout 180`）5 分鐘、整個 deploy job 30 分鐘。正常部署約 20–30 秒。

## 已踩過的坑

- **GHCR 路徑必須全小寫**：repo 名稱是 `DevBuildSample`，workflow 以 `${GITHUB_REPOSITORY,,}` 轉成 `ghcr.io/murmur-wu/devbuildsample/api`。不要直接用 `${{ github.repository }}` 當 image 名稱。
- **兩個 `.env` 不同**：`deploy/.env` 是 `local-up.sh` 自動產生、本地測試用；CD 讀的是 `/srv/myapp/.env`。CD 曾因後者不存在而失敗（`env file /srv/myapp/.env not found`）。
- **port 衝突**：同一台機器上 `local-up.sh` 與 CD 部署綁同樣的 port（Node 3000、.NET 3001），部署前要先 `./scripts/local-up.sh [node|dotnet] down`。
- **.NET 容器內 port 是 8080**：.NET 8 起 aspnet image 預設 8080（Dockerfile 明確設 `ASPNETCORE_HTTP_PORTS=8080`），compose 對應成主機 3001。healthcheck 打的是容器內 8080。
- **.NET runtime image 要用 alpine 版**：標準 `aspnet:10.0` 沒有 curl/wget，healthcheck 會失敗；`aspnet:10.0-alpine` 有 busybox wget。
- **setup-tunnel.sh 每次都要列出全部 hostname**：config 依參數整份重寫，只列一個會把另一個的路由刪掉。
- **更新 tunnel 前先在 buildserver 上 `git checkout main && git pull`**：腳本是在主機上的 clone 執行，不會隨 CD 更新。曾在 PR 合併前用舊版腳本跑新參數（`HOSTNAME/PATH=ORIGIN`），config 沒改成功，`/dotnet/...` 仍被送到 Node 而回 404。確認方式：`sudo cat /etc/cloudflared/config.yml` 要看得到每條 `path:` 規則。
- **改路由時，先部署程式、再更新 tunnel**：順序反過來的話，tunnel 已把新路徑導向還沒部署（或還不認得前綴）的服務，對外會暫時 404/502。
- **cloudflared 轉送時不會去掉路徑前綴**：兩版都靠環境變數 `PATH_BASE`（compose 設定）去掉 `/node`、`/dotnet`。沒帶前綴的請求也要照常處理（本機、healthcheck、CD 的 Verify 都不帶前綴）。`Location` header 要帶回前綴，smoke test 會檢查。
- **.NET 的 `UsePathBase` 後面必須明確呼叫 `UseRouting()`**：Minimal API 預設在最前面自動加 routing，否則比對到的是還帶前綴的路徑，全部 404。
- **Cloudflare 子網域只能一層**：若改用子網域分流，`a.heitang.info` 可以，`api.dotnet.heitang.info` 不在免費 Universal SSL 憑證範圍內。
- **`docker compose up --wait` 需要 healthcheck**：api 與 db 都已定義，新增服務時也要加。
- **不要用 `POSTGRES_PASSWORD_FILE`** 而不定義 compose secrets，postgres 會無法啟動；目前從 `env_file` 讀 `POSTGRES_PASSWORD`。
- **cloudflared 的憑證位置**：`tunnel login/create` 以一般使用者執行，憑證在該使用者的 `~/.cloudflared/`；以 root 跑的服務讀不到，所以 `setup-tunnel.sh` 會複製到 `/etc/cloudflared/`，並用 `sudo cloudflared --config /etc/cloudflared/config.yml service install`。
- **ufw 會鎖掉 SSH**：`ufw default deny incoming` 前必須先 `ufw allow OpenSSH`；`setup-firewall.sh` 預設會保留。
- **Cloudflare 新專案用 Workers，不用 Pages**：官方文件建議新專案改用 Workers Static Assets，Pages 只維護不加新功能。
- **前端不直接呼叫 api-staging**：跨網域會被 CORS 擋，後端也沒有處理 `OPTIONS` 預檢。一律經 Worker 的 `/api/<backend>/` 代轉；新增後端時在 `worker.js` 的 `BACKENDS` 與 `wrangler.jsonc` 的 `vars` 各加一筆。
- **前端不要再加 GitHub Actions 的部署 workflow**：部署已由 Workers Builds 負責，兩邊都部署會重複。Worker 名稱必須與 `wrangler.jsonc` 的 `name`（`devbuildsample-web`）一致，改名要同時改 dashboard。
- **請求紀錄格式兩版一致**：每個請求一行 `方法 路徑 狀態碼 耗時`（例：`POST /node/items 201 5ms`），路徑含前綴、不含 query string，成功的 `/health` 不記。CI 會檢查這個格式；改格式要兩版一起改並更新 `ci-node.yml`、`ci-dotnet.yml`。.NET 的紀錄 middleware 必須放在 `UseExceptionHandler`、`UsePathBase` 之前，才拿得到完整路徑與最終狀態碼。
- **Swagger UI 的 CDN 版本要連同 SRI 一起更新**：`docs/index.html` 的 `integrity` 雜湊取自 npm 上同版本的 `swagger-ui-dist`（`npm pack` 後 `openssl dgst -sha384 -binary <檔案> | openssl base64 -A`），只改版本不改雜湊，瀏覽器會拒絕載入。
- **基底 image 一律以 digest 鎖定**（`node:22-alpine@sha256:…`、`aspnet:10.0-alpine@sha256:…`、`postgres:17@sha256:…`）：曾因 `node:22-alpine` 沒鎖定，官方更新後 buildserver 要重新下載約 55MB 的基底層，加上下載速度只有約 100KB/s，一次部署花了 9 分鐘（.NET 同時只花 12 秒）。更新一律透過 Dependabot 的 PR，合併那次部署會比較久。改 `FROM` 或 compose 的 `image` 時要保留 `@sha256:`。
- **不要讓 postgres 自動升主版本**：17→18 資料目錄格式不相容，直接換 image 會讓 DB 起不來，需要 `pg_upgrade` 或匯出匯入。`dependabot.yml` 已忽略所有主版本升級。
- **`docker compose up --wait` 預設沒有上限**：容器一直重啟時會無限等待並擋住後面排隊的部署，所以一律加 `--wait-timeout`。
- **切換後端時要先清空畫面**：否則新資料回來前會短暫顯示上一個後端的資料（`app.js` 的 `showLoading()`）。
- GitHub Actions 需使用 Node 24 版本的 action（`actions/checkout@v6`、`docker/login-action@v4`、`docker/build-push-action@v7`），舊版會出現 Node 20 停用警告。

## Git 與 PR 慣例

- 在功能分支開發，開 draft PR 合併到 `main`；PR 合併採 squash。
- 合併到 `main` 會自動觸發 CD 部署到 `cd-vm`，合併前確認 CI 綠燈。
