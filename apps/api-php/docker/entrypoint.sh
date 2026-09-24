#!/bin/sh
# 先建立資料表（DB 未就緒會一直重試），再啟動 FrankenPHP。
# migration 放在背景並用 wait 等待，docker stop 的 SIGTERM 才能立刻結束容器，不必等 10 秒被強制終止。
set -e
trap 'kill "$pid" 2>/dev/null; exit 143' TERM INT
php /app/bin/migrate.php &
pid=$!
wait "$pid"
trap - TERM INT
exec frankenphp run --config /etc/frankenphp/Caddyfile
