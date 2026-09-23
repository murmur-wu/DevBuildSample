# DevBuildSample

最小範例後端（Node 22 + PostgreSQL 17），搭配 pull-based CD：GitHub Actions 雲端 build → GHCR → VM 上的 self-hosted runner `docker compose pull && up -d`。架構決策見 [docs/adr/0001-pull-based-deploy.md](docs/adr/0001-pull-based-deploy.md)。

```
apps/api/                     後端原始碼 + Dockerfile（GET /health 會檢查 DB）
deploy/docker-compose.yml     部署用（image 從 GHCR pull）
deploy/docker-compose.local.yml  本地測試 override（改成原始碼 build）
deploy/.env.example           機敏設定範本（真正的 .env 永不進 git）
scripts/local-up.sh           本地一鍵啟動 + 驗證
scripts/smoke-test.sh         端到端測試（health + /items CRUD + 錯誤處理）
scripts/vm/                   部署主機的一次性設定（tunnel、防火牆、維運）
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
- 回滾：Actions → CD → Run workflow，`image_tag` 填舊的 git SHA（會跳過 build 只跑 deploy）。

## 對外服務：Cloudflare Tunnel

在部署主機上以**一般使用者**執行（不要整支用 sudo，腳本需要時會自己 sudo）：

```bash
./scripts/vm/setup-tunnel.sh                          # 預設 api-staging.pic-ai.work、tunnel 名稱 myapp-staging
./scripts/vm/setup-tunnel.sh <hostname> <tunnel名稱>  # 自訂
```

前提：`pic-ai.work` 已在你的 Cloudflare 帳號中。腳本會：安裝 cloudflared → `tunnel login`（印出網址，用瀏覽器授權網域）→ 建立 tunnel → 把憑證複製到 `/etc/cloudflared/`（root、600）→ 寫入 `/etc/cloudflared/config.yml` → 建 DNS CNAME → 安裝 systemd 服務 → 驗證 `https://<hostname>/health`。可重複執行。

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
- 容器 log 上限（每服務 3 × 10MB）寫在 `deploy/docker-compose.yml`，隨 CD 部署生效
