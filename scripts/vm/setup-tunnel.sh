#!/usr/bin/env bash
# 第 5 步：安裝 cloudflared，建立 Cloudflare Tunnel，把 https://<HOSTNAME> 轉到本機服務。
# 在部署主機（buildserver）上，以有 sudo 權限的一般使用者執行（不要用 sudo 執行整支腳本）：
#   ./scripts/vm/setup-tunnel.sh <HOSTNAME[=ORIGIN]>...
#   例：./scripts/vm/setup-tunnel.sh \
#         api-staging.heitang.info=http://127.0.0.1:3000 \
#         api-dotnet-staging.heitang.info=http://127.0.0.1:3001
# - 每次執行都要列出「全部」要對外的 hostname：config 會依參數整份重寫，沒列到的路由會被移除。
# - ORIGIN 省略時為 http://127.0.0.1:3000。
# - 網域必須已在你的 Cloudflare 帳號中；子網域不用先建，腳本會自動建立 CNAME。
#   子網域只能一層（api-dotnet-staging.heitang.info 可以；api.dotnet.heitang.info 不在免費 SSL 憑證範圍內）。
# - tunnel 名稱預設 myapp-staging，可用環境變數 TUNNEL_NAME 覆寫。
# 可重複執行：已完成的步驟會略過。
set -euo pipefail

usage="用法：$0 <HOSTNAME[=ORIGIN]>...
  例：$0 api-staging.heitang.info=http://127.0.0.1:3000 api-dotnet-staging.heitang.info=http://127.0.0.1:3001"
[[ $# -ge 1 ]] || { echo "$usage" >&2; exit 1; }

HOSTS=()
ORIGINS=()
for arg in "$@"; do
  host="${arg%%=*}"
  origin="http://127.0.0.1:3000"
  [[ "$arg" == *=* ]] && origin="${arg#*=}"
  if [[ "$host" != *.* || "$origin" != http*://* ]]; then
    echo "參數格式不對：$arg" >&2
    echo "$usage" >&2
    exit 1
  fi
  HOSTS+=("$host")
  ORIGINS+=("$origin")
done
ZONE="$(awk -F. '{print $(NF-1)"."$NF}' <<<"${HOSTS[0]}")"
for host in "${HOSTS[@]}"; do
  if [[ "$host" != *".$ZONE" ]]; then
    echo "所有 hostname 必須在同一個網域（$ZONE）下：$host" >&2
    exit 1
  fi
done
TUNNEL_NAME="${TUNNEL_NAME:-myapp-staging}"
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
  echo "接下來會印出一個網址：用瀏覽器打開、登入 Cloudflare，並選擇 $ZONE 這個網域授權。"
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
{
  echo "# 由 scripts/vm/setup-tunnel.sh 產生，修改後執行 sudo systemctl restart cloudflared"
  echo "tunnel: $TUNNEL_ID"
  echo "credentials-file: $CRED_DST"
  echo "ingress:"
  for i in "${!HOSTS[@]}"; do
    echo "  - hostname: ${HOSTS[$i]}"
    echo "    service: ${ORIGINS[$i]}"
  done
  echo "  - service: http_status:404"
} | sudo tee "$CONFIG" >/dev/null
sudo cat "$CONFIG"
sudo cloudflared tunnel --config "$CONFIG" ingress validate

step "5/6 設定 DNS"
# --overwrite-dns：若已有同名記錄（例如舊的 A 記錄或舊 tunnel），改指向這個 tunnel
for host in "${HOSTS[@]}"; do
  cloudflared tunnel route dns --overwrite-dns "$TUNNEL_ID" "$host"
done

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

failed=0
for i in "${!HOSTS[@]}"; do
  host="${HOSTS[$i]}"
  step "驗證 https://$host/health"
  ok=0
  for n in $(seq 1 12); do
    if out=$(curl -fsS --max-time 5 "https://$host/health" 2>/dev/null); then
      echo "$out"
      ok=1
      break
    fi
    echo "等待 DNS 與 tunnel 生效…（$n/12）"
    sleep 5
  done
  if [[ $ok -eq 0 ]]; then
    failed=1
    echo "https://$host 1 分鐘內還連不上。DNS 可能需要多幾分鐘；排查：" >&2
    echo "  curl -s ${ORIGINS[$i]}/health   # 確認本機服務正常（服務還沒部署的話先等 CD）" >&2
    echo "  sudo journalctl -u cloudflared -n 50 --no-pager" >&2
    echo "  cloudflared tunnel info $TUNNEL_NAME" >&2
  fi
done
if [[ $failed -eq 0 ]]; then
  echo
  echo "完成：${HOSTS[*]} 都已對外提供服務。"
fi
exit $failed
