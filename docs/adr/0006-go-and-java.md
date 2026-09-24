# ADR 0006：新增 Go 版與 Java 版後端

- 狀態：Accepted
- 日期：2026-09-24

## 背景

繼 Node、.NET、PHP、Python 之後，再用 Go 與 Java 實作同一套 API，沿用 ADR 0002、0004、0005 的方式：獨立資料夾、獨立 DB、獨立 CI/CD，部署到同一台 staging 主機。

## 決策

### Go（`apps/api-go/`，port 3004，`/go`）

1. **只用標準函式庫的 `net/http`**，資料庫用 `pgx/v5` 的連線池（最多 5 條，借出閒置連線前會先 ping）。Go 社群寫小型 API 常不用框架；路由與 Node 版一樣自己比對路徑（Go 1.22 的 `ServeMux` 雖支援 method 與路徑參數，但 404/405 的回應格式要改寫，不如自己比對直接）。
2. **啟動時先建立資料表**（DB 未就緒會重試）才開始 listen；用 `signal.NotifyContext` 處理 SIGTERM，等 DB 時也能立刻結束。
3. **image**：`golang:1.27-alpine` 靜態編譯（`CGO_ENABLED=0`）→ `alpine:3.24` 執行（busybox wget 給 healthcheck 用），執行檔約 11MB。閒置記憶體約 6MB。
4. **測試**：`go test` 測輸入驗證與不需資料庫的 HTTP 行為（`httptest`）；CI 另跑 `gofmt` 與 `go vet`。

### Java（`apps/api-java/`，port 3005，`/java`）

1. **Spring Boot 4 + Java 25（LTS）**，資料庫用 `JdbcTemplate` + HikariCP（最多 5 條）。Java 後端最主流的組合。
   - 考慮過的替代方案：Javalin、JDK 內建 `HttpServer`（較輕量，但實務上少見）、Quarkus / Micronaut（啟動快、記憶體小，但練習價值不如 Spring Boot）。
2. **不用 Spring 的預設行為產生回應**：不用 `@RequestBody`，自己讀 body 並檢查（415/413/400 的訊息才會與其他版一致）；`ApiErrors`（`@RestControllerAdvice`）接手 404、405 與未預期例外，回 `{"error": "..."}`。
3. **路徑前綴**：不能用 `server.servlet.context-path`（沒帶前綴的請求會 404），改用 filter 把前綴包成 context path，Spring MVC 比對路由時會去掉它，`Location` 也用它帶回前綴。請求紀錄是最外層的 filter。
4. **建立資料表放在 `SpringApplication.run` 之前**：Spring 啟動中收到 SIGTERM 時，關閉流程會等啟動完成，DB 一直沒好時 `docker stop` 要等 10 秒。
5. **image**：maven 編譯後以 `jarmode=tools` 分層解開，依賴（約 22MB）與程式（約 100KB）放在不同 layer，平常部署只需下載程式那層（buildserver 下載速度曾經很慢，見 CLAUDE.md）。執行用 `eclipse-temurin:25-jre-alpine`，heap 上限 256MB、Serial GC；閒置記憶體約 190MB，啟動約 3 秒（healthcheck 寬限期 30 秒）。
6. **測試**：JUnit 測輸入驗證，並用 `@SpringBootTest` 啟動真正的 Tomcat 測不需資料庫的 HTTP 行為（連線池要等第一次查詢才會連 DB）。

### 前端

六個後端的切換按鈕在手機寬度一行放不下，560px 以下改為三欄兩列的格狀排列。

## 後果

- 優點：六種語言可以並排比較同一套 API 的寫法、image 大小、記憶體與啟動時間。
- 代價：API 行為要在六處維護；主機多跑兩組 api + db（共六個 PostgreSQL 容器，Java 版的 api 約 190MB）。
- 已知可接受的差異：時間戳精度（Node 毫秒、其他各版微秒）、`GET /` 的 `name`、URL 編碼的 id（例如 `/items/%31`：Node、PHP、Go 回 404，.NET、Python、Java 的框架會先解碼）。
