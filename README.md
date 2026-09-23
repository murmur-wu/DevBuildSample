# DevBuildSample

最小範例後端（Node 22 + PostgreSQL 17），搭配 pull-based CD：GitHub Actions 雲端 build → GHCR → VM 上的 self-hosted runner `docker compose pull && up -d`。架構決策見 [docs/adr/0001-pull-based-deploy.md](docs/adr/0001-pull-based-deploy.md)。

```
apps/api/                     後端原始碼 + Dockerfile（GET /health 會檢查 DB）
deploy/docker-compose.yml     部署用（image 從 GHCR pull）
deploy/docker-compose.local.yml  本地測試 override（改成原始碼 build）
deploy/.env.example           機敏設定範本（真正的 .env 永不進 git）
scripts/local-up.sh           本地一鍵啟動 + 驗證
scripts/smoke-test.sh         端到端測試（health + /items CRUD + 錯誤處理）
.github/workflows/ci.yml      PR / push main 時跑 smoke test
.github/workflows/cd.yml      CD pipeline（部署後也跑 smoke test）
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

# 2. 取得程式碼並啟動
git clone https://github.com/murmur-wu/DevBuildSample.git && cd DevBuildSample
./scripts/local-up.sh
# → 首次會自動產生 deploy/.env（隨機 DB 密碼），build image，等 healthcheck 通過
# → 最後印出 {"status":"ok","db":"ok","version":"local"} 即成功

# 3. 跑 smoke test（19 項檢查，全過會 exit 0）
./scripts/smoke-test.sh                      # 預設打 http://127.0.0.1:3000
./scripts/smoke-test.sh https://api-staging.pic-ai.work   # 也可以打其他環境

# 4. 其他
docker compose -p myapp-local -f deploy/docker-compose.yml logs -f api   # 看 log
./scripts/local-up.sh down    # 停止（保留資料）
./scripts/local-up.sh clean   # 停止並清空 DB
```

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

```bash
curl -s -X POST localhost:3000/items -H 'content-type: application/json' -d '{"name":"買牛奶"}'
curl -s localhost:3000/items
curl -s -X PUT localhost:3000/items/1 -H 'content-type: application/json' -d '{"name":"買牛奶","done":true}'
curl -s -X DELETE localhost:3000/items/1 -i
```

## 部署到 staging VM

見 ADR 的「VM 建置步驟」。重點：
- VM 上建立 `/srv/myapp/.env`（依 `deploy/.env.example`，`chmod 600`，owner `deploy`）。
- self-hosted runner 註冊時帶 `--labels staging`。
- 回滾：Actions → CD → Run workflow，`image_tag` 填舊的 git SHA（會跳過 build 只跑 deploy）。
