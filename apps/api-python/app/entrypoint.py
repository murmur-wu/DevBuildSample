"""容器的啟動程序：先建立資料表，成功後才以 uvicorn 取代本程序（os.execvp，PID 不變）。

DB 可能比 api 晚就緒（例如主機重開機），失敗就重試，與另外三版相同；成功前 api 不會變成 healthy。
不放在 FastAPI 的 lifespan：uvicorn 在啟動階段收到 SIGTERM 不會中斷 lifespan，
DB 一直沒好時 docker stop 要等 10 秒才會強制終止。
"""

import os
import signal
import sys
import time

from .store import migrate

UVICORN = ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080",
           # 請求紀錄由 app/main.py 輸出（格式與另外三版一致）
           "--no-access-log", "--no-server-header"]


def main() -> None:
    # 容器內是 PID 1，沒有預設的 SIGTERM 行為，要自己處理才能讓 docker stop 立刻結束
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    attempt = 1
    while True:
        try:
            migrate()
            break
        except Exception as exc:
            print(f"migration failed (attempt {attempt}): {exc}", file=sys.stderr, flush=True)
            time.sleep(min(attempt, 10))
            attempt += 1
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    os.execvp(UVICORN[0], UVICORN)


if __name__ == "__main__":
    main()
