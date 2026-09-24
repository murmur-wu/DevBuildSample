# ADR 0005：新增 Python 版後端（FastAPI）

- 狀態：Accepted
- 日期：2026-09-24

## 背景

繼 Node、.NET、PHP 之後，用 Python 實作同一套 API，沿用 ADR 0002、0004 的方式：獨立資料夾、獨立 DB、獨立 CI/CD，部署到同一台 staging 主機。

## 決策

1. **框架用 FastAPI + uvicorn，資料庫用 psycopg 3（async）+ psycopg-pool**：目前 Python 寫 API 最主流的組合。
   - 考慮過的替代方案：Flask（較傳統）、只用標準函式庫的 `http.server`（最接近 Node 版，但實務上少見）。
2. **不用 FastAPI 的自動驗證與 `/docs`**：自動驗證的錯誤是 422 + `{"detail": ...}`，與契約（400 + `{"error": ...}`）不同。改為與另外三版一樣自己讀 JSON、自己檢查；路由比對失敗的 404/405 以 exception handler 改成相同訊息。API 文件統一由前端的 Swagger UI（`openapi.yaml`）提供。
3. **路徑前綴與請求紀錄放在最外層的 ASGI app**（`app/main.py` 的 `app()`）：設定 ASGI 的 `root_path` 讓 Starlette 比對去掉前綴後的路徑，`Location` 由 `root_path` 帶回前綴；同一層包住 `send` 取得最終狀態碼，輸出與另外三版相同格式的紀錄。
4. **建立資料表放在 uvicorn 啟動之前**（`app/entrypoint.py`）：DB 未就緒會重試，成功後以 `os.execvp` 換成 uvicorn（PID 不變）。不放在 FastAPI 的 lifespan，因為 uvicorn 在啟動階段收到 SIGTERM 不會中斷 lifespan，`docker stop` 會等 10 秒才強制終止。
5. **連線池**（最多 5 條，與 Node 版的 `pg.Pool` 相同），借出前檢查連線，DB 重啟後不會拿到失效的連線。有連線池的關係，DB 請求約 1–2ms（PHP 版每個請求新開連線，約 10ms）。
6. **依賴版本以 `==` 鎖定**（`requirements.txt`），基底 image 以 digest 鎖定；兩者都由 Dependabot 開 PR 更新。所有套件都有 musllinux 的預編譯版本，image 裡不需要編譯器。
7. **測試**：pytest 測輸入驗證（與 .NET、PHP 版相同的案例），另用 FastAPI 的 TestClient 測不需要資料庫的 HTTP 行為（路徑前綴、錯誤訊息與狀態碼、請求紀錄格式）。
8. **Port 與對外網址**：主機 3003（容器內 8080），對外 `https://api-staging.heitang.info/py/...`，前端 Worker 以 `/api/py/*` 代轉。以非 root 使用者（uid 10001）執行。

## 後果

- 優點：四版可以並排比較；Python 版一樣可以單獨部署、回滾、刪除。
- 代價：API 行為要在四處維護；主機多跑一組 api + db（第四個 Postgres 容器）。
- 已知可接受的差異：時間戳精度（Node 毫秒、其他三版微秒）、`GET /` 的 `name`（`api-python`）。
