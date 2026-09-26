#!/usr/bin/env bash
# 對執行中的 API 跑一輪端到端檢查：health + /items 完整 CRUD + 錯誤處理。
# 只會刪除自己建立的資料，可以安全地對 staging 跑。
# 用法：scripts/smoke-test.sh [BASE_URL]   預設 http://127.0.0.1:3000
#   BASE_URL 可以帶路徑前綴，例如 https://api-staging.heitang.info/dotnet
#   api-staging 受 Cloudflare Access 保護：直接打時要設環境變數 CF_ACCESS_CLIENT_ID、CF_ACCESS_CLIENT_SECRET
#   （service token），經前端 Worker 代轉（<前端網址>/api/<版本>）或打本機則不用
# 依賴：curl、python3（Ubuntu 預設都有）
set -uo pipefail
BASE="${1:-${BASE_URL:-http://127.0.0.1:3000}}"
BASE="${BASE%/}"

# 每個 curl 都會帶上的參數（有設定 Access service token 時加上對應 header）
CURL_AUTH=()
if [[ -n "${CF_ACCESS_CLIENT_ID:-}" && -n "${CF_ACCESS_CLIENT_SECRET:-}" ]]; then
  CURL_AUTH=(-H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET")
fi

pass=0; fail=0
STATUS=""; BODY=""; HEADERS=""
created_id=""

cleanup() {
  [[ -n "$created_id" ]] && curl -s "${CURL_AUTH[@]}" -o /dev/null -X DELETE "$BASE/items/$created_id" || true
}
trap cleanup EXIT

# req METHOD PATH [JSON_BODY]  → 設定 STATUS、BODY
req() {
  local method=$1 path=$2 data=${3-} out
  local hdr; hdr=$(mktemp)
  local args=(-s "${CURL_AUTH[@]}" -D "$hdr" -w $'\n%{http_code}' -X "$method" "$BASE$path")
  [[ -n "$data" ]] && args+=(-H 'content-type: application/json' --data "$data")
  out=$(curl "${args[@]}") || { STATUS=000; BODY="curl failed (API 沒有在 $BASE 運行？)"; rm -f "$hdr"; return; }
  STATUS=${out##*$'\n'}
  BODY=${out%$'\n'*}
  HEADERS=$(tr -d '\r' < "$hdr"); rm -f "$hdr"
}

# header NAME → 取出回應 header 的值（不分大小寫）
header() { awk -v n="$(tr '[:upper:]' '[:lower:]' <<<"$1")" -F': ' 'tolower($1)==n {print $2}' <<<"$HEADERS"; }

# json EXPR  → 對 BODY 求值，例如 json 'd["name"]'
json() {
  python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); v=eval(sys.argv[1]); print(json.dumps(v) if isinstance(v,(bool,list,dict)) or v is None else v)' "$1" <<<"$BODY" 2>/dev/null
}

check() {  # check DESC EXPECTED ACTUAL
  if [[ "$2" == "$3" ]]; then
    printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1))
  else
    printf '  \033[31mFAIL\033[0m %s\n       expected: %s\n       actual:   %s\n       body:     %s\n' "$1" "$2" "$3" "$BODY"
    fail=$((fail + 1))
  fi
}

echo "Smoke test → $BASE"
# BASE_URL 的路徑部分（例如 /dotnet），用來檢查 Location header
BASE_PATH=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.urlparse(sys.argv[1]).path.rstrip("/"))' "$BASE")
name="smoke-$(date +%s)-$RANDOM"

echo "health"
req GET /health
check "GET /health → 200"            200 "$STATUS"
check "db is ok"                     ok  "$(json 'd["db"]')"

echo "create"
req POST /items "{\"name\":\"$name\"}"
check "POST /items → 201"            201 "$STATUS"
created_id=$(json 'd["id"]')
check "returns the name"             "$name" "$(json 'd["name"]')"
check "done defaults to false"       false   "$(json 'd["done"]')"
check "Location header"              "$BASE_PATH/items/$created_id" "$(header location)"

echo "read"
req GET "/items/$created_id"
check "GET /items/:id → 200"         200 "$STATUS"
check "same item"                    "$name" "$(json 'd["name"]')"
req GET /items
check "GET /items → 200"             200 "$STATUS"
check "list contains the item"       true "$(json "any(i['id']==$created_id for i in d)")"

echo "update"
req PUT "/items/$created_id" "{\"name\":\"$name-renamed\",\"done\":true}"
check "PUT /items/:id → 200"         200 "$STATUS"
check "name updated"                 "$name-renamed" "$(json 'd["name"]')"
check "done updated"                 true "$(json 'd["done"]')"

echo "validation"
req POST /items '{"name":""}'
check "empty name → 400"             400 "$STATUS"
req POST /items '{"name":"x","done":"yes"}'
check "non-boolean done → 400"       400 "$STATUS"
req POST /items '{not json'
check "invalid JSON → 400"           400 "$STATUS"
req GET /items/abc
check "non-numeric id → 404"         404 "$STATUS"

echo "delete"
req DELETE "/items/$created_id"
check "DELETE /items/:id → 204"      204 "$STATUS"
req GET "/items/$created_id"
check "deleted item → 404"           404 "$STATUS"
req DELETE "/items/$created_id"
check "delete again → 404"           404 "$STATUS"
created_id=""

echo
echo "結果：$pass passed, $fail failed"
[[ $fail -eq 0 ]]
