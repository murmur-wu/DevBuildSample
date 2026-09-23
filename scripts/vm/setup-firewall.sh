#!/usr/bin/env bash
# 啟用 ufw：拒絕所有進入連線，只保留 SSH（除非明確加上 --no-ssh）。
# runner 與 cloudflared 都只用對外連線，不受影響；API 只綁 127.0.0.1，本來就不對外。
#   sudo ./scripts/vm/setup-firewall.sh            保留 SSH（建議）
#   sudo ./scripts/vm/setup-firewall.sh --no-ssh   連 SSH 都關掉（確定有其他方式登入主機才用）
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "請用 sudo 執行" >&2; exit 1; }

allow_ssh=1
[[ "${1:-}" == "--no-ssh" ]] && allow_ssh=0

# sudo 會清掉 SSH_CONNECTION，所以直接看有沒有已建立的 SSH 連線
if [[ $allow_ssh -eq 0 ]] && ss -Htn state established '( sport = :22 )' | grep -q .; then
  echo "目前有 SSH 連線進來，用 --no-ssh 會把這些連線的使用者鎖在外面。已中止。" >&2
  ss -Htn state established '( sport = :22 )' >&2
  exit 1
fi

command -v ufw >/dev/null || apt-get install -y -q ufw
ufw default deny incoming
ufw default allow outgoing
if [[ $allow_ssh -eq 1 ]]; then
  ufw allow OpenSSH
else
  ufw delete allow OpenSSH >/dev/null 2>&1 || true
fi
ufw --force enable
ufw status verbose
