#!/usr/bin/env bash
# 第 6 步：維運三件套。可重複執行，已設定的項目會略過。
#   sudo ./scripts/vm/setup-maintenance.sh [SWAP_SIZE]   預設 SWAP_SIZE=2G
# 1. 每週清理 7 天前未使用的 Docker image / container / build cache（不動 volume，DB 資料安全）
# 2. swap（已有 swap 就略過）
# 3. 自動安裝安全更新
# 另外：容器 log 大小上限寫在 deploy/docker-compose.yml，隨 CD 部署生效。
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "請用 sudo 執行" >&2; exit 1; }
SWAP_SIZE="${1:-2G}"

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

step "1/3 每週清理 Docker"
[[ -d /etc/cron.weekly ]] || apt-get install -y -q cron
systemctl enable --now cron >/dev/null 2>&1 || true
cat > /etc/cron.weekly/docker-prune <<'CRON'
#!/bin/sh
# 由 scripts/vm/setup-maintenance.sh 產生。清理 7 天前未使用的 image、已停止的 container、build cache。
# 不加 --volumes：DB 資料在 named volume 裡，不能清。
docker system prune -af --filter "until=168h" 2>&1 | logger -t docker-prune
CRON
chmod 755 /etc/cron.weekly/docker-prune
echo "已建立 /etc/cron.weekly/docker-prune（結果寫入 syslog，查詢：journalctl -t docker-prune）"

step "2/3 swap"
if [[ -n "$(swapon --noheadings --show=NAME)" ]]; then
  echo "已有 swap，略過："
  swapon --show
else
  if [[ ! -f /swapfile ]]; then
    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
  fi
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  swapon --show
fi

step "3/3 自動安全更新"
dpkg -s unattended-upgrades >/dev/null 2>&1 || apt-get install -y -q unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'APT'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT
systemctl enable --now unattended-upgrades >/dev/null
echo "unattended-upgrades：$(systemctl is-active unattended-upgrades)"
echo "（預設只裝安全更新、不會自動重開機；檢查：sudo unattended-upgrade --dry-run --debug）"

step "完成"
df -h / | tail -1 | awk '{print "磁碟：已用 "$3" / "$2"（"$5"）"}'
free -h | awk '/^Mem|^Swap/ {print $1" "$2}'
