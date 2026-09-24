# CLAUDE.md

## 語言

- 對話回覆一律使用**繁體中文**。
- git commit 訊息（標題與內文）、PR 標題與描述一律使用**繁體中文**。程式碼中的識別字維持英文；註解可用繁體中文。

## 專案概觀

最小範例後端，同一套 API 有六種實作，各自獨立測試、獨立部署，搭配 pull-based CD。架構決策見 `docs/adr/`（0001 部署方式、0002/0004/0005/0006 各版後端、0003 前端、0007 改用 Docker Hub）。

| 版本（key） | 原始碼 | compose 檔 / project | 本機 port（容器內） | PATH_BASE | CI / CD |
|---|---|---|---|---|---|
| Node（`node`） | `apps/api/`（Node 22，純 node:http + pg） | `docker-compose.yml` / `myapp` | 3000（3000） | `/node` | `ci-node.yml` / `cd-node.yml` |
| .NET（`dotnet`） | `apps/api-dotnet/`（.NET 10 Minimal API + Npgsql） | `docker-compose.dotnet.yml` / `myapp-dotnet` | 3001（8080） | `/dotnet` | `ci-dotnet.yml` / `cd-dotnet.yml` |
| PHP（`php`） | `apps/api-php/`（PHP 8.5 + FrankenPHP，無框架，PDO pgsql） | `docker-compose.php.yml` / `myapp-php` | 3002（8080） | `/php` | `ci-php.yml` / `cd-php.yml` |
| Python（`python`） | `apps/api-python/`（Python 3.14 + FastAPI + uvicorn，psycopg 3） | `docker-compose.python.yml` / `myapp-python` | 3003（8080） | `/py` | `ci-python.yml` / `cd-python.yml` |
| Go（`go`） | `apps/api-go/`（Go 1.27，標準函式庫 net/http + pgx） | `docker-compose.go.yml` / `myapp-go` | 3004（8080） | `/go` | `ci-go.yml` / `cd-go.yml` |
| Java（`java`） | `apps/api-java/`（Java 25 + Spring Boot 4 + JdbcTemplate） | `docker-compose.java.yml` / `myapp-java` | 3005（8080） | `/java` | `ci-java.yml` / `cd-java.yml` |

image 放在 Docker Hub 的 private repo `docker.io/murmur20260202/devbuildsample`，六版共用、以 tag 區分：`<key>-<commit SHA>`（另有 `<key>-latest`）；對外網址為 `https://api-staging.heitang.info<PATH_BASE>/...`。前端 Worker 的後端代號與 PATH_BASE 相同（去掉斜線，例如 `py`、`go`），環境變數為 `NODE_API`、`DOTNET_API`、`PHP_API`、`PY_API`、`GO_API`、`JAVA_API`。

前端 `apps/web/` 部署在 Cloudflare Workers（Static Assets + 一支代轉 Worker，`devbuildsample-web`）：`/api/<代號>/*` 由 `src/worker.js` 代轉到對應的後端（`wrangler.jsonc` 的 `vars`），其他路徑回 `public/` 的靜態檔案。CI：`ci-web.yml`（GitHub Actions）；CD：Cloudflare **Workers Builds**（Git 整合，root directory `apps/web`、watch paths `apps/web/*`，設定在 Cloudflare dashboard，不在 repo 裡）。

**各版 API 必須保持一致**（欄位 snake_case、狀態碼、錯誤訊息），契約寫在 `apps/web/public/openapi.yaml`（OpenAPI 3.1，Swagger UI 在前端的 `/docs/`），共用 `scripts/smoke-test.sh` 驗收。改其中一版的行為時，其他各版也要同步修改，並在 smoke test 補上檢查。已知且可接受的差異：時間戳精度（Node 毫秒，其他各版微秒）、`GET /` 的 `name`（`api` / `api-<key>`）、`/items/%31` 這類 URL 編碼的 id（Node、PHP、Go 比對原始路徑回 404；.NET、Python、Java 的框架會先解碼當成 1）。

```
apps/api/src/server.js                    Node 版 API
apps/api/Dockerfile                       node:22-alpine，npm ci，內建 HEALTHCHECK
apps/api-dotnet/src/Api/Program.cs        .NET 版路由、JSON 讀取與錯誤處理
apps/api-dotnet/src/Api/ItemInput.cs      .NET 版輸入驗證（單元測試對象）
apps/api-dotnet/src/Api/ItemStore.cs      .NET 版 SQL（與 Node 版相同）
apps/api-dotnet/tests/Api.Tests/          xUnit 單元測試
apps/api-dotnet/Dockerfile                sdk:10.0 編譯 → aspnet:10.0-alpine 執行
apps/api-php/public/index.php             PHP 版路由、JSON 讀取、錯誤處理與請求紀錄（Caddyfile 把所有路徑導到這裡）
apps/api-php/src/ItemInput.php            PHP 版輸入驗證（單元測試對象）
apps/api-php/src/ItemStore.php            PHP 版 SQL（時間戳在 SQL 轉成 UTC ISO 8601）
apps/api-php/bin/migrate.php              容器啟動時建立資料表（重試），由 docker/entrypoint.sh 呼叫
apps/api-php/docker/                      Caddyfile、php.ini、entrypoint.sh
apps/api-php/tests/                       PHPUnit 單元測試（composer 只用於測試，正式 image 無外部套件）
apps/api-php/Dockerfile                   frankenphp:1-php8.5-alpine + pdo_pgsql，非 root 執行
apps/api-python/app/main.py               Python 版路由、JSON 讀取、錯誤處理；最外層 ASGI app 處理 PATH_BASE 與請求紀錄
apps/api-python/app/item_input.py         Python 版輸入驗證（單元測試對象）
apps/api-python/app/store.py              Python 版 SQL（psycopg 連線池；時間戳在 SQL 轉成 UTC ISO 8601）
apps/api-python/app/entrypoint.py         容器啟動：建立資料表（重試）後 os.execvp 成 uvicorn
apps/api-python/tests/                    pytest：輸入驗證 + 不需 DB 的 HTTP 行為（TestClient）
apps/api-python/Dockerfile                python:3.14-alpine，套件版本鎖在 requirements.txt，非 root 執行
apps/api-go/main.go                       Go 版路由（自己比對路徑，與 Node 版相同）、PATH_BASE、請求紀錄、啟動時 migration
apps/api-go/item.go                       Go 版輸入驗證（單元測試對象）
apps/api-go/store.go                      Go 版 SQL（pgxpool）
apps/api-go/*_test.go                     go test：輸入驗證 + 不需 DB 的 HTTP 行為（httptest）
apps/api-go/Dockerfile                    golang:1.27-alpine 編譯（CGO_ENABLED=0）→ alpine:3.24 執行，非 root
apps/api-java/src/main/java/devbuildsample/api/   Java 版：ItemController（路由）、ItemInput（驗證）、ItemStore（SQL）、ApiErrors（錯誤格式）、RequestFilters（PATH_BASE 與請求紀錄）、Application（migration 後啟動 Spring）
apps/api-java/src/test/                   JUnit：輸入驗證 + 不需 DB 的 HTTP 行為（啟動真正的 Tomcat）
apps/api-java/Dockerfile                  maven 編譯 → 分層解開 jar → eclipse-temurin:25-jre-alpine 執行，heap 上限 256MB，非 root
deploy/docker-compose.<key>.yml           各版部署用（每版獨立的 DB 容器與 volume；Node 版為 docker-compose.yml）
deploy/docker-compose*.local.yml          本地 override：改為原始碼 build
deploy/.env.example                       機敏設定範本（各版共用 /srv/myapp/.env）
scripts/local-up.sh                       本地一鍵啟動：[node|dotnet|php|python|go|java] [up|down|clean|logs]
scripts/smoke-test.sh [URL]               端到端測試（20 項），各版共用；URL 可帶路徑前綴
scripts/vm/setup-tunnel.sh      部署主機：Cloudflare Tunnel（一般使用者執行）
scripts/vm/setup-firewall.sh    部署主機：ufw，預設保留 SSH（sudo 執行）
scripts/vm/setup-maintenance.sh 部署主機：Docker 清理、swap、自動安全更新（sudo 執行）
.github/workflows/ci-<key>.yml            各版 CI：單元測試（Node 版沒有）+ smoke test（有/無前綴）+ 請求紀錄格式檢查
.github/workflows/cd-<key>.yml            各版 CD：呼叫 _build-deploy.yml
.github/workflows/_build-deploy.yml       共用：雲端 build → Docker Hub → self-hosted runner 部署 → /health → smoke test
.github/workflows/ci-web.yml              前端：wrangler dev 代轉到本機六個後端，跑 smoke test
.github/actionlint.yaml                   宣告自訂 runner label（staging），供 actionlint 檢查
.github/dependabot.yml                    每週檢查基底 image（Dockerfile、compose）、pip / Go 模組 / Maven 套件與 GitHub Actions 更新，開 PR；不提議主版本升級
apps/web/public/                          前端靜態頁面（純 HTML/CSS/JS，無 build 步驟）
apps/web/src/worker.js                    API 代轉，改寫 Location header
apps/web/wrangler.jsonc                   Worker 設定：run_worker_first ["/api/*"]、vars
apps/web/public/openapi.yaml              API 規格（各版共同契約）；servers 為各後端的 /api/<代號>（經 Worker 代轉）
apps/web/public/docs/                     Swagger UI（jsDelivr 載入 swagger-ui-dist，固定版本 + SRI）
apps/web/redocly.yaml                     OpenAPI 檢查規則（npm run lint:openapi）
```

API：`GET /health`（會查 DB，失敗回 503）、`GET /`、`/items` CRUD（GET 列表、POST、GET/PUT/DELETE `/items/:id`）。`items` 資料表在啟動時以 `CREATE TABLE IF NOT EXISTS` 建立，DB 未就緒會重試。

## 常用指令

```bash
./scripts/local-up.sh [key]         # build + 啟動 + 等 healthy + 打 /health（預設 node；key 見上表）
./scripts/smoke-test.sh [URL]       # 預設 http://127.0.0.1:3000；其他版用上表的 port
./scripts/local-up.sh <key> down    # 停止（保留資料）
./scripts/local-up.sh <key> clean   # 停止並刪除 DB volume
./scripts/local-up.sh <key> logs    # 容器 log
docker run --rm -v "$PWD/apps/api-dotnet:/src" -w /src mcr.microsoft.com/dotnet/sdk:10.0 dotnet test   # .NET 單元測試
docker run --rm -v "$PWD/apps/api-php:/app" -w /app composer:2 sh -c 'composer install && vendor/bin/phpunit'   # PHP 單元測試
docker run --rm -v "$PWD/apps/api-python:/app" -w /app python:3.14-alpine sh -c 'pip install -r requirements-dev.txt && python -m pytest -p no:cacheprovider'   # Python 單元測試
docker run --rm -v "$PWD/apps/api-go:/src" -w /src golang:1.27-alpine go test ./...   # Go 單元測試（CI 另跑 gofmt、go vet）
docker run --rm -v "$PWD/apps/api-java:/src" -w /src maven:3-eclipse-temurin-25-alpine mvn -B -q test   # Java 單元測試
actionlint                                  # 改 workflow 後檢查（設定在 .github/actionlint.yaml）
cd apps/web && cp .dev.vars.example .dev.vars && npm run dev   # 前端本機開發（先啟動各後端），http://127.0.0.1:8787
./scripts/smoke-test.sh http://127.0.0.1:8787/api/node          # 經 Worker 代轉跑 smoke test
cd apps/web && npm run lint:openapi                              # 檢查 OpenAPI 規格
sudo docker logs -f myapp-api-1                                  # staging 上看 Node 的請求紀錄（其他版：myapp-<key>-api-1）
sudo docker exec myapp-db-1 psql -U postgres -d app -c 'SELECT * FROM items;'   # 直接查資料庫
```

修改 API 後，送出前至少對改到的那一版跑一次 `local-up.sh` + `smoke-test.sh`（有單元測試的版本另跑單元測試）。新增 endpoint 或改變行為時：各版都要實作、同步更新 `openapi.yaml`（並跑 `npm run lint:openapi`）、在 `smoke-test.sh` 補上檢查，並更新 README 的 API 表格。

## 部署環境（staging）

- runner：`cd-vm`，label `staging`，跑在主機 `buildserver` 上，以 `deploy` 使用者執行（systemd 服務 `actions.runner.murmur-wu-DevBuildSample.cd-vm`）。
- compose project 名稱：Node `myapp`、其他版 `myapp-<key>`（本地測試加上 `-local`）。各有自己的 DB 容器與 volume，互不影響。
- CI/CD 依路徑觸發（見各 workflow 的 `paths`）：改 `apps/api-dotnet/` 只跑 .NET 的 CI/CD；改 `scripts/smoke-test.sh` 或 `_build-deploy.yml` 會各版都跑。所有 CD 的 deploy 都在同一個 runner 上，會排隊依序執行。
- 機敏設定：VM 上的 `/srv/myapp/.env`（owner `deploy`、`chmod 600`），**永不進 git**。必須包含 `POSTGRES_PASSWORD`。
- 服務只綁 127.0.0.1，對外走 Cloudflare Tunnel `myapp-staging`，同一個網址用路徑分流：`https://api-staging.heitang.info/node/...` → `127.0.0.1:3000`、`/dotnet/...` → `127.0.0.1:3001`、`/php/...` → `127.0.0.1:3002`、`/py/...` → `127.0.0.1:3003`、`/go/...` → `127.0.0.1:3004`、`/java/...` → `127.0.0.1:3005`，其他路徑 404。設定在 `/etc/cloudflared/config.yml`，憑證在 `/etc/cloudflared/<tunnel-id>.json`（root、600），systemd 服務 `cloudflared`。
- 容器 log 上限在各 compose 檔的 `x-logging`；新增服務時要加上 `logging: *logging`。
- image tag 為 `<key>-<git SHA>`；回滾：Actions → 該版的 CD（例如 CD (Go)）→ Run workflow，`image_tag` 填舊 SHA（會跳過 build）。只能回滾到改用 Docker Hub 之後的 commit，之前的 image 在 GHCR。
- CD 需要 repo secrets `DOCKERHUB_USERNAME`（`murmur20260202`）與 `DOCKERHUB_TOKEN`（Docker Hub 的 Read & Write access token），各 `cd-<key>.yml` 以 `secrets: inherit` 傳給 `_build-deploy.yml`。token 到期或外洩時：Docker Hub → Account settings → Personal access tokens 重新產生，再更新 GitHub secret。
- CD 部署後依序跑 `/health` 驗證與 smoke test；`/health` 回傳的 `version` 應等於部署的 commit SHA。
- CD 的時間上限：`Pull images` 20 分鐘、`Deploy`（`up --wait --wait-timeout 180`）5 分鐘、整個 deploy job 30 分鐘。正常部署約 20–30 秒。

## 已踩過的坑

- **不用 GHCR，改用 Docker Hub**：buildserver 從 GHCR 下載只有約 35–70KB/s（大一點的層還會卡住），Docker Hub 約 6MB/s 以上；主機沒有 IPv6、MTU 1500 正常，換 DNS 也無效（GHCR 用 anycast，每個 DNS 給的 IP 都一樣），是網路業者到 GitHub CDN 的線路問題。Java 第一次部署曾花 15 分鐘下載。見 ADR 0007。
- **Docker Hub 免費方案只有 1 個 private repo**：六個後端共用 `devbuildsample`，以 tag 前綴（`<key>-`）區分；新增後端時沿用同一個 repo，不要另開。repo 名稱必須全小寫。
- **reusable workflow 拿不到呼叫端的 secrets**：`cd-<key>.yml` 呼叫 `_build-deploy.yml` 時要寫 `secrets: inherit`，否則 Docker Hub 登入會因 secret 未提供而失敗。
- **兩個 `.env` 不同**：`deploy/.env` 是 `local-up.sh` 自動產生、本地測試用；CD 讀的是 `/srv/myapp/.env`。CD 曾因後者不存在而失敗（`env file /srv/myapp/.env not found`）。
- **port 衝突**：同一台機器上 `local-up.sh` 與 CD 部署綁同樣的 port（見上表），部署前要先 `./scripts/local-up.sh <key> down`。
- **.NET 容器內 port 是 8080**：.NET 8 起 aspnet image 預設 8080（Dockerfile 明確設 `ASPNETCORE_HTTP_PORTS=8080`），compose 對應成主機 3001。healthcheck 打的是容器內 8080。
- **.NET runtime image 要用 alpine 版**：標準 `aspnet:10.0` 沒有 curl/wget，healthcheck 會失敗；`aspnet:10.0-alpine` 有 busybox wget。
- **setup-tunnel.sh 每次都要列出全部 hostname**：config 依參數整份重寫，只列一個會把另一個的路由刪掉。
- **更新 tunnel 前先在 buildserver 上 `git checkout main && git pull`**：腳本是在主機上的 clone 執行，不會隨 CD 更新。曾在 PR 合併前用舊版腳本跑新參數（`HOSTNAME/PATH=ORIGIN`），config 沒改成功，`/dotnet/...` 仍被送到 Node 而回 404。確認方式：`sudo cat /etc/cloudflared/config.yml` 要看得到每條 `path:` 規則。
- **改路由時，先部署程式、再更新 tunnel**：順序反過來的話，tunnel 已把新路徑導向還沒部署（或還不認得前綴）的服務，對外會暫時 404/502。
- **cloudflared 轉送時不會去掉路徑前綴**：各版都靠環境變數 `PATH_BASE`（compose 設定）去掉前綴。沒帶前綴的請求也要照常處理（本機、healthcheck、CD 的 Verify 都不帶前綴）。`Location` header 要帶回前綴，smoke test 會檢查。
- **.NET 的 `UsePathBase` 後面必須明確呼叫 `UseRouting()`**：Minimal API 預設在最前面自動加 routing，否則比對到的是還帶前綴的路徑，全部 404。
- **Cloudflare 子網域只能一層**：若改用子網域分流，`a.heitang.info` 可以，`api.dotnet.heitang.info` 不在免費 Universal SSL 憑證範圍內。
- **`docker compose up --wait` 需要 healthcheck**：api 與 db 都已定義，新增服務時也要加。
- **不要用 `POSTGRES_PASSWORD_FILE`** 而不定義 compose secrets，postgres 會無法啟動；目前從 `env_file` 讀 `POSTGRES_PASSWORD`。
- **cloudflared 的憑證位置**：`tunnel login/create` 以一般使用者執行，憑證在該使用者的 `~/.cloudflared/`；以 root 跑的服務讀不到，所以 `setup-tunnel.sh` 會複製到 `/etc/cloudflared/`，並用 `sudo cloudflared --config /etc/cloudflared/config.yml service install`。
- **ufw 會鎖掉 SSH**：`ufw default deny incoming` 前必須先 `ufw allow OpenSSH`；`setup-firewall.sh` 預設會保留。
- **Cloudflare 新專案用 Workers，不用 Pages**：官方文件建議新專案改用 Workers Static Assets，Pages 只維護不加新功能。
- **前端不直接呼叫 api-staging**：跨網域會被 CORS 擋，後端也沒有處理 `OPTIONS` 預檢。一律經 Worker 的 `/api/<backend>/` 代轉；新增後端時在 `worker.js` 的 `BACKENDS` 與 `wrangler.jsonc` 的 `vars` 各加一筆。
- **前端不要再加 GitHub Actions 的部署 workflow**：部署已由 Workers Builds 負責，兩邊都部署會重複。Worker 名稱必須與 `wrangler.jsonc` 的 `name`（`devbuildsample-web`）一致，改名要同時改 dashboard。
- **請求紀錄格式各版一致**：每個請求一行 `方法 路徑 狀態碼 耗時`（例：`POST /node/items 201 5ms`），路徑含前綴、不含 query string，成功的 `/health` 不記。CI 會檢查這個格式；改格式要各版一起改並更新各 `ci-<key>.yml`。.NET 的紀錄 middleware 必須放在 `UseExceptionHandler`、`UsePathBase` 之前，才拿得到完整路徑與最終狀態碼。
- **Swagger UI 的 CDN 版本要連同 SRI 一起更新**：`docs/index.html` 的 `integrity` 雜湊取自 npm 上同版本的 `swagger-ui-dist`（`npm pack` 後 `openssl dgst -sha384 -binary <檔案> | openssl base64 -A`），只改版本不改雜湊，瀏覽器會拒絕載入。
- **基底 image 一律以 digest 鎖定**（`node:22-alpine@sha256:…`、`aspnet:10.0-alpine@sha256:…`、`frankenphp:1-php8.5-alpine@sha256:…`、`python:3.14-alpine@sha256:…`、`golang`/`alpine`、`maven`/`eclipse-temurin`、`postgres:17@sha256:…`）：曾因 `node:22-alpine` 沒鎖定，官方更新後 buildserver 要重新下載約 55MB 的基底層，加上下載速度只有約 100KB/s，一次部署花了 9 分鐘（.NET 同時只花 12 秒）。更新一律透過 Dependabot 的 PR，合併那次部署會比較久。改 `FROM` 或 compose 的 `image` 時要保留 `@sha256:`。
- **Java 的編譯 image 不跟 Dependabot 換 JDK**：`maven:3-eclipse-temurin-25-alpine` 的版本號是開頭的 Maven 3，JDK 25 在後綴裡，Dependabot 曾開 PR 把它換成非 LTS 的 JDK 26（PR #12，已關閉）。`dependabot.yml` 對 `maven` 忽略小版本與修訂版更新，只保留 digest 更新；編譯與執行一律用同一個 Java LTS（目前 25），要換時手動改 Dockerfile、`pom.xml` 的 `java.version` 與 `ci-java.yml`。
- **不要讓 postgres 自動升主版本**：17→18 資料目錄格式不相容，直接換 image 會讓 DB 起不來，需要 `pg_upgrade` 或匯出匯入。`dependabot.yml` 已忽略所有主版本升級。
- **`docker compose up --wait` 預設沒有上限**：容器一直重啟時會無限等待並擋住後面排隊的部署，所以一律加 `--wait-timeout`。
- **FrankenPHP 官方 image 沒有 PostgreSQL 驅動**：Dockerfile 以 image 內建的 `install-php-extensions pdo_pgsql` 安裝（build 時要能連到 Alpine 套件庫）。
- **PHP 沒有「程式啟動時」**：每個請求都重新執行 `index.php`，所以建立資料表放在容器的 entrypoint（`bin/migrate.php`，DB 未就緒會重試），成功後才 `exec frankenphp run`。migration 在背景執行並 `wait`，`docker stop` 才能立刻結束。
- **PHP 的布林轉換**：`(bool) 'f'` 是 `true`，DB 回來的布林值不要直接轉型（見 `ItemStore.php`）。
- **PHP 的名稱長度以 UTF-16 計算**（`mb_convert_encoding` 後除以 2），與 Node 的 `String.length`、.NET 的 `string.Length` 一致；`mb_strlen` 算的是字元數，emoji 會少算。
- **FastAPI 的自動驗證不要用**：錯誤會回 422 與 `{"detail": ...}`，與契約不同。Python 版自己讀 JSON、自己檢查，並用 exception handler 把路由的 404/405 改成與其他版相同的訊息（只有 `/items` 相關路徑回 405，其他一律 404）；FastAPI 內建的 `/docs` 也關閉。
- **Python 的 PATH_BASE 用 ASGI `root_path`**：Starlette 比對路由時會從 `path` 去掉 `root_path`，所以 `path` 要保留完整路徑、只設定 `root_path`（見 `app/main.py` 最下面的 `app()`）。
- **Python 的建立資料表不放在 FastAPI 的 lifespan**：uvicorn 在啟動階段收到 SIGTERM 不會中斷 lifespan，DB 一直沒好時 `docker stop` 要等 10 秒被強制終止。改由 `app/entrypoint.py` 建好資料表後 `os.execvp` 成 uvicorn。
- **psycopg 連線池要設 `check`**：DB 重啟後池裡的舊連線會失效，借出前檢查才不會讓重啟後的第一批請求失敗。
- **pip 解析 Alpine 套件時要同時指定 musllinux_1_1 與 1_2**（`pip download --platform ...`）：pydantic-core 只有 musllinux_1_1 的 wheel，只指定 1_2 會退回舊版 FastAPI + pydantic v1。容器內的 pip 會自動判斷，只有在主機上替容器下載時才要注意。
- **Starlette 1.x 的 TestClient 用 `httpx2`**：用 `httpx` 會出現棄用警告。
- **Go 的 JSON 物件欄位順序**：`map` 會依字母排序（`{"db":…,"status":…}`），要與其他版相同順序時用 struct。空的 slice 要輸出 `[]` 不是 `null`（`store.go` 的 `List`）。
- **Go 程式是容器的 PID 1**：要用 `signal.NotifyContext` 處理 SIGTERM（等 DB 時也要能中斷），否則 `docker stop` 要等 10 秒被強制終止。
- **Spring Boot 的路徑前綴不能用 `server.servlet.context-path`**：設了之後沒帶前綴的請求（本機、healthcheck）會 404。改用 filter 把前綴包成 context path（`RequestFilters.pathBaseFilter`），Spring MVC 比對路由時會自動去掉。
- **Spring Boot 的錯誤格式要自己接手**：`ApiErrors` 處理 404（`NoHandlerFoundException`，需 `spring.web.resources.add-mappings=false`）、405、未預期例外；`@RequestBody` 不用，自己讀 body 才能與其他版回同樣的 415/413/400 訊息。
- **Java 的 migration 放在 `SpringApplication.run` 之前**：Spring 啟動中收到 SIGTERM 時，關閉流程會等啟動完成，DB 一直沒好時 `docker stop` 要等 10 秒。
- **Java image 分層**：`java -Djarmode=tools -jar api.jar extract --layers` 把依賴（約 22MB）和程式（約 100KB）分成不同 layer，平常部署只需下載程式那層；heap 以 `-Xmx256m` 限制，實測閒置約 190MB。
- **Spring Boot 4 用 Jackson 3**：套件是 `tools.jackson.*`（不是 `com.fasterxml.jackson.databind`），`isTextual()`/`asText()` 改名為 `isString()`/`stringValue()`；註解（`@JsonInclude` 等）仍在 `com.fasterxml.jackson.annotation`。
- **前端的後端按鈕**：超過五個在手機上一行放不下，`style.css` 在 560px 以下改成三欄格狀排列；再加後端時要確認手機寬度（320px）沒有橫向捲動。
- **切換後端時要先清空畫面**：否則新資料回來前會短暫顯示上一個後端的資料（`app.js` 的 `showLoading()`）。
- GitHub Actions 需使用 Node 24 版本的 action（`actions/checkout@v7`、`docker/login-action@v4`、`docker/build-push-action@v7`），舊版會出現 Node 20 停用警告。

## Git 與 PR 慣例

- 在功能分支開發，開 draft PR 合併到 `main`；PR 合併採 squash。
- 合併到 `main` 會自動觸發 CD 部署到 `cd-vm`，合併前確認 CI 綠燈。
