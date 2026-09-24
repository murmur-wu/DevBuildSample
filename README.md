# DevBuildSample

最小範例後端，同一套 API 有兩種實作，各自獨立測試與部署：

| | Node 版 | .NET 版 |
|---|---|---|
| 原始碼 | `apps/api/`（Node 22） | `apps/api-dotnet/`（.NET 10、ASP.NET Core Minimal API） |
| 本機 port | 3000 | 3001 |
| 資料庫 | 各自一個 PostgreSQL 17 容器與 volume | 同左 |
| 對外網址 | `https://api-staging.heitang.info/node/...` | `https://api-staging.heitang.info/dotnet/...` |
| CI / CD | `ci-node.yml` / `cd-node.yml` | `ci-dotnet.yml`（含 `dotnet test`）/ `cd-dotnet.yml` |

兩者 API 完全相同，共用 `scripts/smoke-test.sh` 驗收。對外共用同一個網址，用路徑前綴分流（見「對外服務」）。

前端（`apps/web/`）是部署在 Cloudflare Workers 的待辦清單頁面，可切換 Node / .NET 後端；瀏覽器只呼叫同網域的 `/api/...`，由 Worker 代轉到後端（見「前端」）。CI/CD 依修改的路徑觸發：改 `apps/api-dotnet/` 只會跑 .NET 的流程，反之亦然。

部署採 pull-based CD：GitHub Actions 雲端 build → GHCR → VM 上的 self-hosted runner `docker compose pull && up -d`。架構決策見 [docs/adr/0001-pull-based-deploy.md](docs/adr/0001-pull-based-deploy.md)。

```
apps/api/                              Node 版原始碼 + Dockerfile
apps/api-dotnet/                       .NET 版：src/Api（API）、tests/Api.Tests（xUnit）、Dockerfile
apps/web/                              前端：public/（靜態頁面）、src/worker.js（API 代轉）、wrangler.jsonc
deploy/docker-compose.yml              Node 版部署用（compose project：myapp）
deploy/docker-compose.dotnet.yml       .NET 版部署用（compose project：myapp-dotnet）
deploy/docker-compose*.local.yml       本地測試 override（改成原始碼 build）
deploy/.env.example                    機敏設定範本（真正的 .env 永不進 git；兩版共用）
scripts/local-up.sh                    本地一鍵啟動 + 驗證：local-up.sh [node|dotnet] [up|down|clean|logs]
scripts/smoke-test.sh                  端到端測試（health + /items CRUD + 錯誤處理），兩版共用
scripts/vm/                            部署主機的一次性設定（tunnel、防火牆、維運）
.github/workflows/ci-node.yml          Node：smoke test
.github/workflows/ci-dotnet.yml        .NET：dotnet test + smoke test
.github/workflows/cd-node.yml          Node：build → GHCR → 部署
.github/workflows/cd-dotnet.yml        .NET：build → GHCR → 部署
.github/workflows/_build-deploy.yml    兩個 CD 共用的 build + deploy 流程
.github/workflows/ci-web.yml           前端：wrangler dev + 經代轉跑兩個後端的 smoke test
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

# 2. 取得程式碼並啟動（兩版可以同時跑）
git clone https://github.com/murmur-wu/DevBuildSample.git && cd DevBuildSample
./scripts/local-up.sh node      # Node 版 → http://127.0.0.1:3000（省略 node 也可以）
./scripts/local-up.sh dotnet    # .NET 版 → http://127.0.0.1:3001
# → 首次會自動產生 deploy/.env（隨機 DB 密碼），build image，等 healthcheck 通過
# → 最後印出 {"status":"ok","db":"ok","version":"local"} 即成功

# 3. 跑 smoke test（20 項檢查，全過會 exit 0）
./scripts/smoke-test.sh                          # 預設打 Node 版 http://127.0.0.1:3000
./scripts/smoke-test.sh http://127.0.0.1:3001    # .NET 版
./scripts/smoke-test.sh http://127.0.0.1:3001/dotnet    # 帶路徑前綴（模擬經 tunnel 的請求）
./scripts/smoke-test.sh https://api-staging.heitang.info/dotnet   # 也可以打其他環境

# 4. 其他（app 參數：node 或 dotnet）
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

## API

| Method | Path | 說明 | 成功 | 錯誤 |
|---|---|---|---|---|
| GET | `/health` | 檢查 API 與 DB | 200 | 503（DB 連不上） |
| GET | `/items` | 列出全部 | 200 | |
| POST | `/items` | 新增，body `{"name": "...", "done": false}` | 201 + `Location` | 400 / 415 |
| GET | `/items/:id` | 取得單筆 | 200 | 404 |
| PUT | `/items/:id` | 整筆更新，body 同 POST | 200 | 400 / 404 |
| DELETE | `/items/:id` | 刪除 | 204 | 404 |

`name` 必填、最多 200 字；`done` 選填，須為布林。`items` 資料表在 API 啟動時自動建立（DB 還沒好會重試）。

兩版回應相同（欄位 snake_case、狀態碼與錯誤訊息一致），唯一差異：`created_at` / `updated_at` 的精度，Node 為毫秒、.NET 為微秒（都是 ISO 8601）。`GET /` 的 `name` 分別為 `api`、`api-dotnet`。

```bash
curl -s -X POST localhost:3000/items -H 'content-type: application/json' -d '{"name":"買牛奶"}'
curl -s localhost:3000/items
curl -s -X PUT localhost:3000/items/1 -H 'content-type: application/json' -d '{"name":"買牛奶","done":true}'
curl -s -X DELETE localhost:3000/items/1 -i
```

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
- 回滾：Actions → **CD (Node)** 或 **CD (.NET)** → Run workflow，`image_tag` 填舊的 git SHA（會跳過 build 只跑 deploy）。
- 兩版的部署都跑在同一個 runner（`cd-vm`）上，同時觸發時會排隊依序執行。

## 對外服務：Cloudflare Tunnel

在部署主機上以**一般使用者**執行（不要整支用 sudo，腳本需要時會自己 sudo）：

```bash
./scripts/vm/setup-tunnel.sh \
  api-staging.heitang.info/node=http://127.0.0.1:3000 \
  api-staging.heitang.info/dotnet=http://127.0.0.1:3001
```

同一個網址用路徑前綴分流：

```
https://api-staging.heitang.info/node/items    → Node（127.0.0.1:3000）
https://api-staging.heitang.info/dotnet/items  → .NET（127.0.0.1:3001）
https://api-staging.heitang.info/其他路徑       → 404
```

- **cloudflared 轉送時不會去掉前綴**：`/dotnet/items` 送到 .NET 時路徑仍是 `/dotnet/items`。所以兩個服務都用環境變數 `PATH_BASE`（設在 compose 檔）自己去掉前綴；沒帶前綴的請求（本機、healthcheck）照常處理。
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
- 容器 log 上限（每服務 3 × 10MB）寫在兩個 compose 檔，隨 CD 部署生效

## 前端（Cloudflare Workers）

```
瀏覽器 ──► https://devbuildsample-web.<你的子網域>.workers.dev
             ├─ /、/app.js、/style.css      → 靜態檔案（apps/web/public）
             ├─ /api/node/*                 → Worker 代轉 → https://api-staging.heitang.info/node/*
             └─ /api/dotnet/*               → Worker 代轉 → https://api-staging.heitang.info/dotnet/*
```

瀏覽器只跟同一個網域溝通，所以沒有跨網域（CORS）問題，後端也不用改。後端的 `Location` header（例如 `/node/items/1`）會被改寫成 `/api/node/items/1`。代轉目標設定在 `apps/web/wrangler.jsonc` 的 `vars`（`NODE_API`、`DOTNET_API`）。

### 本機開發

```bash
./scripts/local-up.sh node && ./scripts/local-up.sh dotnet    # 先啟動兩個後端
cd apps/web
npm install
cp .dev.vars.example .dev.vars    # 讓 Worker 代轉到本機後端
npm run dev                        # http://127.0.0.1:8787
../../scripts/smoke-test.sh http://127.0.0.1:8787/api/dotnet   # 經代轉跑 smoke test
```

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
```

### 綁自訂網域（選用）

在 `apps/web/wrangler.jsonc` 加上：

```jsonc
"routes": [{ "pattern": "app-staging.heitang.info", "custom_domain": true }]
```

合併後 Workers Builds 部署時會自動建立 DNS 與憑證。子網域一樣只能一層。

