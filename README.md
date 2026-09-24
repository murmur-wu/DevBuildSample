# DevBuildSample

最小範例後端，同一套 API 有六種實作，各自獨立測試與部署（每版各有一個 PostgreSQL 17 容器與 volume）：

| 版本 | 原始碼 | 本機 port | 對外網址（`https://api-staging.heitang.info` 之後） | CI / CD |
|---|---|---|---|---|
| Node 22 | `apps/api/` | 3000 | `/node/...` | `ci-node.yml` / `cd-node.yml` |
| .NET 10（ASP.NET Core Minimal API） | `apps/api-dotnet/` | 3001 | `/dotnet/...` | `ci-dotnet.yml`（含 `dotnet test`）/ `cd-dotnet.yml` |
| PHP 8.5（FrankenPHP） | `apps/api-php/` | 3002 | `/php/...` | `ci-php.yml`（含 PHPUnit）/ `cd-php.yml` |
| Python 3.14（FastAPI） | `apps/api-python/` | 3003 | `/py/...` | `ci-python.yml`（含 pytest）/ `cd-python.yml` |
| Go 1.27（標準函式庫 net/http） | `apps/api-go/` | 3004 | `/go/...` | `ci-go.yml`（含 go test）/ `cd-go.yml` |
| Java 25（Spring Boot 4） | `apps/api-java/` | 3005 | `/java/...` | `ci-java.yml`（含 JUnit）/ `cd-java.yml` |

各版 API 完全相同，共用 `scripts/smoke-test.sh` 驗收。對外共用同一個網址，用路徑前綴分流（見「對外服務」）。

前端（`apps/web/`）是部署在 Cloudflare Workers 的待辦清單頁面，可切換六個後端；瀏覽器只呼叫同網域的 `/api/...`，由 Worker 代轉到後端（見「前端」）。CI/CD 依修改的路徑觸發：改 `apps/api-dotnet/` 只會跑 .NET 的流程，其他各版也一樣。

部署採 pull-based CD：GitHub Actions 雲端 build → GHCR → VM 上的 self-hosted runner `docker compose pull && up -d`。架構決策見 [docs/adr/0001-pull-based-deploy.md](docs/adr/0001-pull-based-deploy.md)。

```
apps/api/                              Node 版原始碼 + Dockerfile
apps/api-dotnet/                       .NET 版：src/Api（API）、tests/Api.Tests（xUnit）、Dockerfile
apps/api-php/                          PHP 版：public/index.php（路由）、src/（驗證與 SQL）、tests/（PHPUnit）、Dockerfile
apps/api-python/                       Python 版：app/main.py（路由）、app/item_input.py、app/store.py、tests/（pytest）、Dockerfile
apps/api-go/                           Go 版：main.go（路由）、item.go（驗證）、store.go（SQL）、*_test.go、Dockerfile
apps/api-java/                         Java 版：src/main/java/devbuildsample/api/、src/test/（JUnit）、pom.xml、Dockerfile
apps/web/                              前端：public/（靜態頁面）、src/worker.js（API 代轉）、wrangler.jsonc
apps/web/public/openapi.yaml           API 規格（OpenAPI 3.1，各版共同的契約），Swagger UI 在 /docs/
deploy/docker-compose.yml              Node 版部署用（compose project：myapp）
deploy/docker-compose.dotnet.yml       .NET 版部署用（compose project：myapp-dotnet）
deploy/docker-compose.php.yml          PHP 版部署用（compose project：myapp-php）
deploy/docker-compose.python.yml       Python 版部署用（compose project：myapp-python）
deploy/docker-compose.go.yml           Go 版部署用（compose project：myapp-go）
deploy/docker-compose.java.yml         Java 版部署用（compose project：myapp-java）
deploy/docker-compose*.local.yml       本地測試 override（改成原始碼 build）
deploy/.env.example                    機敏設定範本（真正的 .env 永不進 git；各版共用）
scripts/local-up.sh                    本地一鍵啟動 + 驗證：local-up.sh [node|dotnet|php|python|go|java] [up|down|clean|logs]
scripts/smoke-test.sh                  端到端測試（health + /items CRUD + 錯誤處理），各版共用
scripts/vm/                            部署主機的一次性設定（tunnel、防火牆、維運）
.github/workflows/ci-node.yml          Node：smoke test
.github/workflows/ci-dotnet.yml        .NET：dotnet test + smoke test
.github/workflows/ci-php.yml           PHP：phpunit + smoke test
.github/workflows/ci-python.yml        Python：pytest + smoke test
.github/workflows/ci-go.yml            Go：gofmt、go vet、go test + smoke test
.github/workflows/ci-java.yml          Java：mvn test + smoke test
.github/workflows/cd-node.yml          Node：build → GHCR → 部署
.github/workflows/cd-dotnet.yml        .NET：build → GHCR → 部署
.github/workflows/cd-php.yml           PHP：build → GHCR → 部署
.github/workflows/cd-python.yml        Python：build → GHCR → 部署
.github/workflows/cd-go.yml            Go：build → GHCR → 部署
.github/workflows/cd-java.yml          Java：build → GHCR → 部署
.github/workflows/_build-deploy.yml    各版 CD 共用的 build + deploy 流程
.github/workflows/ci-web.yml           前端：wrangler dev + 經代轉跑六個後端的 smoke test
```

## 在本地 Ubuntu 測試後端

只需要 Docker（部署步驟的第 1 步），不需要 runner、tunnel、GHCR。

```bash
# 1. 裝 Docker Engine（官方 repo）
sudo apt update && sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list
sudo apt update   # 若 docker repo 404，把 docker.list 內的 codename 改成 noble
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo usermod -aG docker $USER && newgrp docker

# 2. 取得程式碼並啟動（各版可以同時跑）
git clone https://github.com/murmur-wu/DevBuildSample.git && cd DevBuildSample
./scripts/local-up.sh node      # Node 版 → http://127.0.0.1:3000（省略 node 也可以）
./scripts/local-up.sh dotnet    # .NET 版 → http://127.0.0.1:3001
./scripts/local-up.sh php       # PHP 版 → http://127.0.0.1:3002
./scripts/local-up.sh python    # Python 版 → http://127.0.0.1:3003
./scripts/local-up.sh go        # Go 版 → http://127.0.0.1:3004
./scripts/local-up.sh java      # Java 版 → http://127.0.0.1:3005
# → 首次會自動產生 deploy/.env（隨機 DB 密碼），build image，等 healthcheck 通過
# → 最後印出 {"status":"ok","db":"ok","version":"local"} 即成功

# 3. 跑 smoke test（20 項檢查，全過會 exit 0）
./scripts/smoke-test.sh                          # 預設打 Node 版 http://127.0.0.1:3000
./scripts/smoke-test.sh http://127.0.0.1:3001    # .NET 版
./scripts/smoke-test.sh http://127.0.0.1:3002    # PHP 版
./scripts/smoke-test.sh http://127.0.0.1:3003    # Python 版（Go :3004、Java :3005）
./scripts/smoke-test.sh http://127.0.0.1:3001/dotnet    # 帶路徑前綴（模擬經 tunnel 的請求）
./scripts/smoke-test.sh https://api-staging.heitang.info/dotnet   # 也可以打其他環境

# 4. 其他（app 參數：node、dotnet、php、python、go 或 java）
./scripts/local-up.sh dotnet logs    # 看 log
./scripts/local-up.sh dotnet down    # 停止（保留資料）
./scripts/local-up.sh dotnet clean   # 停止並清空 DB
```

### .NET 單元測試

本機不用裝 .NET SDK，用官方 SDK 容器執行（CI 也是這樣跑）：

```bash
docker run --rm -v "$PWD/apps/api-dotnet:/src" -w /src mcr.microsoft.com/dotnet/sdk:10.0 dotnet test
```

有裝 .NET 10 SDK 的話，直接在 `apps/api-dotnet/` 執行 `dotnet test`。

### PHP 單元測試

一樣用官方容器（composer 映像檔內含 PHP），CI 也是這樣跑：

```bash
docker run --rm -v "$PWD/apps/api-php:/app" -w /app composer:2 sh -c 'composer install && vendor/bin/phpunit'
```

composer 只用來裝 PHPUnit；正式 image 沒有任何外部套件，只多裝了 PostgreSQL 驅動（`pdo_pgsql`）。

### Python 單元測試

```bash
docker run --rm -v "$PWD/apps/api-python:/app" -w /app python:3.14-alpine sh -c 'pip install -r requirements-dev.txt && python -m pytest -p no:cacheprovider'
```

除了輸入驗證，也用 FastAPI 的 TestClient 測不需要資料庫的 HTTP 行為（路徑前綴、404/405/413/415/400 的訊息、請求紀錄格式）。

### Go 與 Java 單元測試

```bash
docker run --rm -v "$PWD/apps/api-go:/src" -w /src golang:1.27-alpine go test ./...
docker run --rm -v "$PWD/apps/api-java:/src" -w /src maven:3-eclipse-temurin-25-alpine mvn -B -q test
```

兩版都和 Python 版一樣，除了輸入驗證也測不需要資料庫的 HTTP 行為（Go 用 `httptest`，Java 啟動真正的 Tomcat）。

## API

完整規格：[`apps/web/public/openapi.yaml`](apps/web/public/openapi.yaml)（OpenAPI 3.1，各版共同的契約）。
互動式文件（Swagger UI）：前端網址的 `/docs/`，例如 `https://devbuildsample-web.<子網域>.workers.dev/docs/`。上方 **Servers** 可切換後端，「Try it out」會經前端 Worker 代轉到 staging 後端，**會實際寫入資料庫**。

| Method | Path | 說明 | 成功 | 錯誤 |
|---|---|---|---|---|
| GET | `/health` | 檢查 API 與 DB | 200 | 503（DB 連不上） |
| GET | `/items` | 列出全部 | 200 | |
| POST | `/items` | 新增，body `{"name": "...", "done": false}` | 201 + `Location` | 400 / 415 |
| GET | `/items/:id` | 取得單筆 | 200 | 404 |
| PUT | `/items/:id` | 整筆更新，body 同 POST | 200 | 400 / 404 |
| DELETE | `/items/:id` | 刪除 | 204 | 404 |

`name` 必填、最多 200 字；`done` 選填，須為布林。`items` 資料表在 API 啟動時自動建立（DB 還沒好會重試）。

各版回應相同（欄位 snake_case、狀態碼與錯誤訊息一致），唯一差異：`created_at` / `updated_at` 的精度，Node 為毫秒、其他各版為微秒（都是 ISO 8601）。`GET /` 的 `name` 分別為 `api`、`api-dotnet`、`api-php`、`api-python`、`api-go`、`api-java`。

```bash
curl -s -X POST localhost:3000/items -H 'content-type: application/json' -d '{"name":"買牛奶"}'
curl -s localhost:3000/items
curl -s -X PUT localhost:3000/items/1 -H 'content-type: application/json' -d '{"name":"買牛奶","done":true}'
curl -s -X DELETE localhost:3000/items/1 -i
```

## 觀察後端：請求紀錄與資料庫

每個後端每收到一個請求都會寫一行紀錄，格式相同：`方法 路徑 狀態碼 耗時`（路徑含前綴、不含 query string；成功的 `/health` 不記，避免 healthcheck 洗版）。

```bash
# 在 buildserver 上即時看請求（在前端操作時會一行一行出現）
sudo docker logs -f --since 5m myapp-api-1           # Node
sudo docker logs -f --since 5m myapp-dotnet-api-1    # .NET
sudo docker logs -f --since 5m myapp-php-api-1       # PHP
sudo docker logs -f --since 5m myapp-python-api-1    # Python（Go：myapp-go-api-1、Java：myapp-java-api-1）
# 例：
#   POST /node/items 201 5ms
#   PUT /node/items/3 200 3ms
#   GET /node/items/abc 404 0ms

# 直接查資料庫，確認資料真的寫進去（-U / -d 對應 /srv/myapp/.env 的 POSTGRES_USER / POSTGRES_DB）
sudo docker exec myapp-db-1        psql -U postgres -d app -c 'SELECT * FROM items ORDER BY id;'
sudo docker exec myapp-dotnet-db-1 psql -U postgres -d app -c 'SELECT * FROM items ORDER BY id;'
sudo docker exec myapp-php-db-1    psql -U postgres -d app -c 'SELECT * FROM items ORDER BY id;'
sudo docker exec myapp-python-db-1 psql -U postgres -d app -c 'SELECT * FROM items ORDER BY id;'   # 其他版：myapp-<版本>-db-1
```

本機測試時容器名稱是 `myapp-local-*`（Node）、`myapp-<版本>-local-*`（其他版），或用 `./scripts/local-up.sh <版本> logs`。

## 部署到 staging VM

見 ADR 的「VM 建置步驟」。重點：
- VM 上建立 `/srv/myapp/.env`（依 `deploy/.env.example`，`chmod 600`，owner `deploy`）。

  ```bash
  sudo mkdir -p /srv/myapp && sudo chown deploy:deploy /srv/myapp
  sudo -u deploy bash -c 'umask 077; cat > /srv/myapp/.env <<EOF
  POSTGRES_USER=postgres
  POSTGRES_PASSWORD=$(openssl rand -hex 16)
  POSTGRES_DB=app
  EOF'
  ```

  CD 的「Check env file」步驟會在部署前檢查這個檔案，缺少時直接失敗並提示。
- self-hosted runner 註冊時帶 `--labels staging`。
- 記憶體：每版一組 api + PostgreSQL。本機實測閒置時 api 約 Go 6MB、Python 55MB、Java 190MB（heap 上限 256MB），每個 PostgreSQL 約 25–40MB。主機記憶體吃緊時可先停掉不用的版本：`sudo docker compose -p myapp-<版本> -f deploy/docker-compose.<版本>.yml down`（資料保留）。
- 基底 image（各版的執行環境與 PostgreSQL）以 digest 鎖定，平常部署只下載幾 KB 的程式層，約 20–30 秒完成；基底更新由 Dependabot 每週一開 PR，合併那次部署會比較久。部署步驟有時間上限（下載 20 分鐘、啟動 3 分鐘），卡住會直接失敗並印出容器 log。
- 回滾：Actions → 該版的 **CD (…)**（例如 **CD (Go)**）→ Run workflow，`image_tag` 填舊的 git SHA（會跳過 build 只跑 deploy）。
- 各版的部署都跑在同一個 runner（`cd-vm`）上，同時觸發時會排隊依序執行。

## 對外服務：Cloudflare Tunnel

在部署主機上以**一般使用者**執行（不要整支用 sudo，腳本需要時會自己 sudo）：

```bash
./scripts/vm/setup-tunnel.sh \
  api-staging.heitang.info/node=http://127.0.0.1:3000 \
  api-staging.heitang.info/dotnet=http://127.0.0.1:3001 \
  api-staging.heitang.info/php=http://127.0.0.1:3002 \
  api-staging.heitang.info/py=http://127.0.0.1:3003 \
  api-staging.heitang.info/go=http://127.0.0.1:3004 \
  api-staging.heitang.info/java=http://127.0.0.1:3005
```

執行前先 `git checkout main && git pull`（腳本是在主機上的 clone 執行，不會隨 CD 更新）。新增後端時要**先**等它的 CD 部署成功，**再**更新 tunnel，否則新路徑會暫時 404/502。

同一個網址用路徑前綴分流：

```
https://api-staging.heitang.info/node/items    → Node（127.0.0.1:3000）
https://api-staging.heitang.info/dotnet/items  → .NET（127.0.0.1:3001）
https://api-staging.heitang.info/php/items     → PHP（127.0.0.1:3002）
https://api-staging.heitang.info/py/items      → Python（127.0.0.1:3003）
https://api-staging.heitang.info/go/items      → Go（127.0.0.1:3004）
https://api-staging.heitang.info/java/items    → Java（127.0.0.1:3005）
https://api-staging.heitang.info/其他路徑       → 404
```

- **cloudflared 轉送時不會去掉前綴**：`/dotnet/items` 送到 .NET 時路徑仍是 `/dotnet/items`。所以每個服務都用環境變數 `PATH_BASE`（設在 compose 檔）自己去掉前綴；沒帶前綴的請求（本機、healthcheck）照常處理。
- 每次都要列出**全部**路由：config 會依參數整份重寫，沒列到的路由會被移除。
- 參數格式 `HOSTNAME[/PATH][=ORIGIN]`：`/PATH` 比對 `/PATH` 與 `/PATH/...`（不會誤中 `/PATHx`）；`=ORIGIN` 省略時為 `http://127.0.0.1:3000`；tunnel 名稱預設 `myapp-staging`（環境變數 `TUNNEL_NAME` 可覆寫）。
- 前提：`heitang.info` 已在你的 Cloudflare 帳號中；子網域不用先建，腳本會自動建立 CNAME。登入授權時要選 `heitang.info`。
- 若改用不同子網域分流（例如 `a.heitang.info=...`），子網域只能一層；`api.dotnet.heitang.info` 這種兩層的不在 Cloudflare 免費 SSL 憑證範圍內。

腳本會：安裝 cloudflared → `tunnel login`（印出網址，用瀏覽器授權網域）→ 建立 tunnel → 把憑證複製到 `/etc/cloudflared/`（root、600）→ 寫入 `/etc/cloudflared/config.yml` → 建 DNS CNAME → 安裝 systemd 服務 → 驗證 `https://<hostname>/health`。可重複執行。

確認 tunnel 正常後再開防火牆：

```bash
sudo ./scripts/vm/setup-firewall.sh            # 拒絕所有進入連線，但保留 SSH（建議）
```

runner 與 cloudflared 都只用對外連線，不受影響。`--no-ssh` 會連 SSH 都關掉，只有在確定有其他方式登入主機時才用（腳本偵測到有 SSH 連線會拒絕執行）。

## 維運

```bash
sudo ./scripts/vm/setup-maintenance.sh          # swap 預設 2G，可傳參數如 4G
```

- 每週清理 7 天前未使用的 Docker image / container / build cache（不動 volume，DB 資料安全）；紀錄：`journalctl -t docker-prune`
- 沒有 swap 時建立 `/swapfile`
- 啟用 unattended-upgrades 自動安裝安全更新（不會自動重開機）
- 容器 log 上限（每服務 3 × 10MB）寫在各 compose 檔，隨 CD 部署生效

## 前端（Cloudflare Workers）

```
瀏覽器 ──► https://devbuildsample-web.<你的子網域>.workers.dev
             ├─ /、/app.js、/style.css      → 靜態檔案（apps/web/public）
             ├─ /api/node/*                 → Worker 代轉 → https://api-staging.heitang.info/node/*
             ├─ /api/dotnet/*               → Worker 代轉 → https://api-staging.heitang.info/dotnet/*
             ├─ /api/php/*                  → Worker 代轉 → https://api-staging.heitang.info/php/*
             ├─ /api/py/*                   → Worker 代轉 → https://api-staging.heitang.info/py/*
             ├─ /api/go/*                   → Worker 代轉 → https://api-staging.heitang.info/go/*
             └─ /api/java/*                 → Worker 代轉 → https://api-staging.heitang.info/java/*
```

瀏覽器只跟同一個網域溝通，所以沒有跨網域（CORS）問題，後端也不用改。後端的 `Location` header（例如 `/node/items/1`）會被改寫成 `/api/node/items/1`。代轉目標設定在 `apps/web/wrangler.jsonc` 的 `vars`（`NODE_API`、`DOTNET_API`、`PHP_API`、`PY_API`、`GO_API`、`JAVA_API`）。

### 本機開發

```bash
for app in node dotnet php python go java; do ./scripts/local-up.sh $app; done    # 先啟動六個後端
cd apps/web
npm install
cp .dev.vars.example .dev.vars    # 讓 Worker 代轉到本機後端
npm run dev                        # http://127.0.0.1:8787
../../scripts/smoke-test.sh http://127.0.0.1:8787/api/dotnet   # 經代轉跑 smoke test
npm run lint:openapi               # 檢查 OpenAPI 規格
```

Swagger UI 在 http://127.0.0.1:8787/docs/（由 jsDelivr 載入 swagger-ui-dist，固定版本並以 SRI 驗證）。

### 部署：Cloudflare Workers Builds（Git 整合，只設定一次）

部署由 Cloudflare 直接連 GitHub repo 處理，GitHub 上不需要放任何 Cloudflare token。PR 的測試仍由 GitHub Actions 的 `ci-web.yml` 負責。

1. Cloudflare dashboard → **Workers & Pages** → **Create** → **Import a repository** → 選 GitHub，授權 **Cloudflare Workers & Pages** GitHub App 存取 `murmur-wu/DevBuildSample`。
2. 設定：

   | 欄位 | 值 |
   |---|---|
   | Project name | `devbuildsample-web`（**必須**與 `apps/web/wrangler.jsonc` 的 `name` 相同，否則 build 會失敗） |
   | Production branch | `main` |
   | Root directory | `apps/web` |
   | Build command | 留空（沒有 build 步驟） |
   | Deploy command | `npx wrangler deploy` |
   | Build watch paths（Settings → Builds） | Include：`apps/web/*`（只有前端變動才部署） |

3. 第一次使用 Workers 時會要求設定 workers.dev 子網域（例如 `murmur`），網址會是 `https://devbuildsample-web.murmur.workers.dev`。

之後只要改 `apps/web/` 並合併到 `main`，Cloudflare 就會自動部署；GitHub 的 commit 旁會出現 Cloudflare 的 check run。部署後可以手動跑一次完整驗證：

```bash
./scripts/smoke-test.sh https://devbuildsample-web.<子網域>.workers.dev/api/node
./scripts/smoke-test.sh https://devbuildsample-web.<子網域>.workers.dev/api/dotnet
./scripts/smoke-test.sh https://devbuildsample-web.<子網域>.workers.dev/api/php
./scripts/smoke-test.sh https://devbuildsample-web.<子網域>.workers.dev/api/py
./scripts/smoke-test.sh https://devbuildsample-web.<子網域>.workers.dev/api/go
./scripts/smoke-test.sh https://devbuildsample-web.<子網域>.workers.dev/api/java
```

### 綁自訂網域（選用）

在 `apps/web/wrangler.jsonc` 加上：

```jsonc
"routes": [{ "pattern": "app-staging.heitang.info", "custom_domain": true }]
```

合併後 Workers Builds 部署時會自動建立 DNS 與憑證。子網域一樣只能一層。

