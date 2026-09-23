# CLAUDE.md

## 語言

- 對話回覆一律使用**繁體中文**。
- git commit 訊息（標題與內文）、PR 標題與描述一律使用**繁體中文**。程式碼中的識別字維持英文；註解可用繁體中文。

## 專案概觀

最小範例後端（Node 22 + PostgreSQL 17），搭配 pull-based CD。架構決策見 `docs/adr/0001-pull-based-deploy.md`。

```
apps/api/src/server.js          API（純 node:http + pg，無框架）
apps/api/Dockerfile             node:22-alpine，npm ci，內建 HEALTHCHECK
deploy/docker-compose.yml       部署用：image 從 GHCR pull
deploy/docker-compose.local.yml 本地 override：改為原始碼 build
deploy/.env.example             機敏設定範本
scripts/local-up.sh             本地一鍵啟動（up / down / clean）
scripts/smoke-test.sh           端到端測試（19 項）
.github/workflows/ci.yml        PR 與 push main：起服務 + smoke test
.github/workflows/cd.yml        push main：雲端 build → GHCR → self-hosted runner 部署
```

API：`GET /health`（會查 DB，失敗回 503）、`GET /`、`/items` CRUD（GET 列表、POST、GET/PUT/DELETE `/items/:id`）。`items` 資料表在啟動時以 `CREATE TABLE IF NOT EXISTS` 建立，DB 未就緒會重試。

## 常用指令

```bash
./scripts/local-up.sh          # build + 啟動 + 等 healthy + 打 /health
./scripts/smoke-test.sh [URL]  # 預設 http://127.0.0.1:3000，只依賴 curl、python3
./scripts/local-up.sh down     # 停止（保留資料）
./scripts/local-up.sh clean    # 停止並刪除 DB volume
```

修改 API 後，送出前至少跑一次 `local-up.sh` + `smoke-test.sh`。新增 endpoint 時同步在 `smoke-test.sh` 補上檢查，並更新 README 的 API 表格。

## 部署環境（staging）

- runner：`cd-vm`，label `staging`，跑在主機 `buildserver` 上，以 `deploy` 使用者執行（systemd 服務 `actions.runner.murmur-wu-DevBuildSample.cd-vm`）。
- compose project 名稱：`myapp`（本地測試用 `myapp-local`）。
- 機敏設定：VM 上的 `/srv/myapp/.env`（owner `deploy`、`chmod 600`），**永不進 git**。必須包含 `POSTGRES_PASSWORD`。
- 服務只綁 `127.0.0.1:3000`，對外預計走 Cloudflare Tunnel（`api-staging.pic-ai.work`，尚未設定）。
- image tag 使用 git SHA；回滾：Actions → CD → Run workflow，`image_tag` 填舊 SHA（會跳過 build）。
- CD 部署後依序跑 `/health` 驗證與 smoke test；`/health` 回傳的 `version` 應等於部署的 commit SHA。

## 已踩過的坑

- **GHCR 路徑必須全小寫**：repo 名稱是 `DevBuildSample`，workflow 以 `${GITHUB_REPOSITORY,,}` 轉成 `ghcr.io/murmur-wu/devbuildsample/api`。不要直接用 `${{ github.repository }}` 當 image 名稱。
- **兩個 `.env` 不同**：`deploy/.env` 是 `local-up.sh` 自動產生、本地測試用；CD 讀的是 `/srv/myapp/.env`。CD 曾因後者不存在而失敗（`env file /srv/myapp/.env not found`）。
- **port 3000 衝突**：同一台機器上 `local-up.sh` 與 CD 部署都綁 `127.0.0.1:3000`，部署前要先 `./scripts/local-up.sh down`。
- **`docker compose up --wait` 需要 healthcheck**：api 與 db 都已定義，新增服務時也要加。
- **不要用 `POSTGRES_PASSWORD_FILE`** 而不定義 compose secrets，postgres 會無法啟動；目前從 `env_file` 讀 `POSTGRES_PASSWORD`。
- GitHub Actions 需使用 Node 24 版本的 action（`actions/checkout@v6`、`docker/login-action@v4`、`docker/build-push-action@v7`），舊版會出現 Node 20 停用警告。

## Git 與 PR 慣例

- 在功能分支開發，開 draft PR 合併到 `main`；PR 合併採 squash。
- 合併到 `main` 會自動觸發 CD 部署到 `cd-vm`，合併前確認 CI 綠燈。
