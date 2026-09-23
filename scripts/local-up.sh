#!/usr/bin/env bash
# 在本地 Ubuntu 上用原始碼 build 並啟動 api + db，最後打 /health 驗證。
# 用法：scripts/local-up.sh        啟動並驗證
#       scripts/local-up.sh down   停止（保留 DB volume）
#       scripts/local-up.sh clean  停止並刪除 DB volume
set -euo pipefail
cd "$(dirname "$0")/../deploy"

export ENV_FILE="$PWD/.env"
compose() { docker compose -p myapp-local -f docker-compose.yml -f docker-compose.local.yml "$@"; }

case "${1:-up}" in
  down)  compose down; exit ;;
  clean) compose down -v; exit ;;
esac

if [[ ! -f .env ]]; then
  cp .env.example .env
  sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 16)/" .env
  chmod 600 .env
  echo "已產生 deploy/.env（隨機 DB 密碼）"
fi

compose up -d --build --wait
curl -fsS http://127.0.0.1:3000/health && echo
echo "OK：後端已在 http://127.0.0.1:3000 運行"
