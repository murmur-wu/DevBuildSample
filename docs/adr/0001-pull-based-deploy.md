# ADR 0001：Pull-based 部署 + Cloudflare Tunnel

- 狀態：Accepted
- 日期：2026-09-23

## 背景

Staging 後端跑在單台 Ubuntu VM。希望 VM 不對外開任何 port（含 SSH）、部署可追溯可回滾，且 build 不佔用 VM 資源。

## 決策

1. **Build 在雲端**：`push main` → GitHub-hosted runner build image → 推到 GHCR，tag 為 git SHA（`ghcr.io/murmur-wu/devbuildsample/api:<sha>`；GHCR 路徑必須全小寫，workflow 以 `${GITHUB_REPOSITORY,,}` 轉換）。
2. **Deploy 採 pull-based**：VM 上的 self-hosted runner（label `staging`，以 `deploy` 使用者跑 systemd 服務）只做 outbound 連線領 job，執行 `docker compose pull && up -d --wait`，再 `curl /health` 驗證。失敗即 workflow 紅燈。
3. **對外走 Cloudflare Tunnel**：api 只綁 `127.0.0.1:3000`，由 `cloudflared` 轉給 `api-staging.pic-ai.work`。防火牆 `ufw default deny incoming`。
4. **機敏設定放 VM**：`/srv/myapp/.env`（`chmod 600`），被 compose 的 `env_file` 讀取，永不進 git。範本為 `deploy/.env.example`。

## 回滾

Actions → CD → Run workflow，`image_tag` 填舊 SHA。build job 會被跳過，deploy job 直接 pull 該 SHA 的 image。

## 後果

- 優點：零 inbound port；每次部署對應一個 commit；VM 只需 Docker + runner + cloudflared。
- 代價：`deploy` 使用者在 `docker` 群組 ≈ root 權限，這台 VM 只做部署、不共用；runner 離線時部署會排隊等待。
- 加 prod：再註冊一個 label `prod` 的 runner 實例、另一份 compose project（換 port 與 hostname），deploy job 掛 GitHub Environments 手動核准。

## VM 建置步驟摘要

1. 安裝 Docker Engine（見 README）。
2. `useradd -m -s /bin/bash deploy && usermod -aG docker deploy`；`mkdir -p /srv/myapp && chown deploy:deploy /srv/myapp`；建立 `/srv/myapp/.env`。
3. 以 `deploy` 身分安裝 runner：`./config.sh --url https://github.com/murmur-wu/DevBuildSample --token <TOKEN> --name cd-vm --labels staging --unattended`，再 `sudo ./svc.sh install deploy && sudo ./svc.sh start`。
4. cloudflared：`./scripts/vm/setup-tunnel.sh`（一般使用者執行）。確認 `https://api-staging.pic-ai.work/health` 正常後，`sudo ./scripts/vm/setup-firewall.sh`（預設保留 SSH）。
5. 維運：`sudo ./scripts/vm/setup-maintenance.sh`（每週 Docker 清理、swap、unattended-upgrades）；容器 log 上限在 compose 內。
