#!/usr/bin/env bash
# 在本地 Ubuntu 上用原始碼 build 並啟動 api + db，最後打 /health 驗證。
# 用法：scripts/local-up.sh [node|dotnet|php|python] [up|down|clean|logs]
#   app     node（預設，port 3000）、dotnet（3001）、php（3002）或 python（3003）；可同時執行
#   up      啟動並驗證（預設）
#   down    停止（保留 DB volume）
#   clean   停止並刪除 DB volume
#   logs    輸出容器 log
set -euo pipefail
cd "$(dirname "$0")/../deploy"

app=node
if [[ "${1:-}" =~ ^(node|dotnet|php|python)$ ]]; then
  app=$1
  shift
fi
case $app in
  node)   project=myapp-local;        files=(-f docker-compose.yml -f docker-compose.local.yml);               port=3000 ;;
  dotnet) project=myapp-dotnet-local; files=(-f docker-compose.dotnet.yml -f docker-compose.dotnet.local.yml); port=3001 ;;
  php)    project=myapp-php-local;    files=(-f docker-compose.php.yml -f docker-compose.php.local.yml);       port=3002 ;;
  python) project=myapp-python-local; files=(-f docker-compose.python.yml -f docker-compose.python.local.yml); port=3003 ;;
esac

export ENV_FILE="$PWD/.env"
compose() { docker compose -p "$project" "${files[@]}" "$@"; }

case "${1:-up}" in
  up)    ;;
  down)  compose down; exit ;;
  clean) compose down -v; exit ;;
  logs)  compose logs --no-color; exit ;;
  *)     echo "用法：$0 [node|dotnet|php|python] [up|down|clean|logs]" >&2; exit 1 ;;
esac

if [[ ! -f .env ]]; then
  cp .env.example .env
  sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 16)/" .env
  chmod 600 .env
  echo "已產生 deploy/.env（隨機 DB 密碼）"
fi

compose up -d --build --wait
curl -fsS "http://127.0.0.1:$port/health" && echo
echo "OK：$app 後端已在 http://127.0.0.1:$port 運行"
