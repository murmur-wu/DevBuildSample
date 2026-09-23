#!/usr/bin/env bash
# 第 5 步：安裝 cloudflared，建立 Cloudflare Tunnel，把 https://<HOSTNAME> 轉到本機 127.0.0.1:3000。
# 在部署主機（buildserver）上，以有 sudo 權限的一般使用者執行（不要用 sudo 執行整支腳本）：
#   ./scripts/vm/setup-tunnel.sh [HOSTNAME] [TUNNEL_NAME]
# 預設：HOSTNAME=api-staging.pic-ai.work、TUNNEL_NAME=myapp-staging
# 可重複執行：已完成的步驟會略過，config 會以目前參數重寫並重啟服務。
set -euo pipefail

HOSTNAME_="${1:-api-staging.pic-ai.work}"
TUNNEL_NAME="${2:-myapp-staging}"
ORIGIN="${ORIGIN:-http://127.0.0.1:3000}"
ETC_DIR=/etc/cloudflared
CONFIG="$ETC_DIR/config.yml"

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

if [[ $EUID -eq 0 ]]; then
  echo "請用一般使用者執行（腳本內需要時會自己 sudo），cloudflared 登入憑證要放在你的家目錄。" >&2
  exit 1
fi

step "1/6 安裝 cloudflared"
if command -v cloudflared >/dev/null; then
  echo "已安裝：$(cloudflared --version)"
else
  sudo mkdir -p --mode=0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" |
    sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
  sudo apt-get update -q && sudo apt-get install -y -q cloudflared
fi

step "2/6 登入 Cloudflare"
if [[ -f "$HOME/.cloudflared/cert.pem" ]]; then
  echo "已登入（$HOME/.cloudflared/cert.pem）"
else
  echo "接下來會印出一個網址：用瀏覽器打開、登入 Cloudflare，並選擇 ${HOSTNAME_#*.} 這個網域授權。"
  cloudflared tunnel login
fi

step "3/6 建立 tunnel：$TUNNEL_NAME"
tunnel_id() {
  cloudflared tunnel list --name "$TUNNEL_NAME" --output json 2>/dev/null |
    python3 -c 'import json,sys; t=json.load(sys.stdin) or []; print(t[0]["id"] if t else "")'
}
TUNNEL_ID="$(tunnel_id)"
if [[ -n "$TUNNEL_ID" ]]; then
  echo "已存在：$TUNNEL_ID"
else
  cloudflared tunnel create "$TUNNEL_NAME"
  TUNNEL_ID="$(tunnel_id)"
fi
[[ -n "$TUNNEL_ID" ]] || { echo "找不到 tunnel $TUNNEL_NAME 的 ID" >&2; exit 1; }

CRED_SRC="$HOME/.cloudflared/$TUNNEL_ID.json"
CRED_DST="$ETC_DIR/$TUNNEL_ID.json"
if ! sudo test -f "$CRED_DST"; then
  [[ -f "$CRED_SRC" ]] || { echo "找不到憑證 $CRED_SRC（tunnel 可能是在別台機器建立的）" >&2; exit 1; }
  sudo install -d -m 755 "$ETC_DIR"
  sudo install -m 600 -o root -g root "$CRED_SRC" "$CRED_DST"
fi
echo "憑證：$CRED_DST（root，600）"

step "4/6 寫入 $CONFIG"
sudo install -d -m 755 "$ETC_DIR"
sudo tee "$CONFIG" >/dev/null <<EOF
# 由 scripts/vm/setup-tunnel.sh 產生，修改後執行 sudo systemctl restart cloudflared
tunnel: $TUNNEL_ID
credentials-file: $CRED_DST
ingress:
  - hostname: $HOSTNAME_
    service: $ORIGIN
  - service: http_status:404
EOF
sudo cloudflared tunnel --config "$CONFIG" ingress validate

step "5/6 設定 DNS：$HOSTNAME_ → tunnel"
# --overwrite-dns：若已有同名記錄（例如舊的 A 記錄或舊 tunnel），改指向這個 tunnel
cloudflared tunnel route dns --overwrite-dns "$TUNNEL_ID" "$HOSTNAME_"

step "6/6 安裝並啟動 systemd 服務"
if systemctl list-unit-files cloudflared.service --no-legend 2>/dev/null | grep -q cloudflared; then
  sudo systemctl restart cloudflared
else
  sudo cloudflared --config "$CONFIG" service install
fi
sudo systemctl enable --now cloudflared >/dev/null 2>&1 || true
if systemctl is-active --quiet cloudflared; then
  echo "cloudflared：active (running)"
else
  echo "cloudflared 服務沒有起來，請看：sudo journalctl -u cloudflared -n 50 --no-pager" >&2
  exit 1
fi

step "驗證 https://$HOSTNAME_/health"
for i in $(seq 1 12); do
  if out=$(curl -fsS --max-time 5 "https://$HOSTNAME_/health" 2>/dev/null); then
    echo "$out"
    echo
    echo "完成：https://$HOSTNAME_ 已對外提供服務。"
    exit 0
  fi
  echo "等待 DNS 與 tunnel 生效…（$i/12）"
  sleep 5
done
echo "1 分鐘內還連不上。DNS 可能需要多幾分鐘；可用下列指令排查：" >&2
echo "  sudo journalctl -u cloudflared -n 50 --no-pager" >&2
echo "  cloudflared tunnel info $TUNNEL_NAME" >&2
echo "  curl -s http://127.0.0.1:3000/health   # 確認本機 API 正常" >&2
exit 1
