# ADR 0004：新增 PHP 版後端（FrankenPHP）

- 狀態：Accepted
- 日期：2026-09-24

## 背景

繼 Node 與 .NET 之後，想用 PHP 實作同一套 API，並沿用 ADR 0002 的方式：獨立資料夾、獨立 DB、獨立 CI/CD，部署到同一台 staging 主機。

PHP 和另外兩版最大的不同在執行方式：Node 與 .NET 本身就是常駐的 HTTP 伺服器；PHP 傳統上要搭配網頁伺服器（nginx + php-fpm 或 Apache），且每個請求都重新執行腳本。

## 決策

1. **執行環境用 FrankenPHP**（`dunglas/frankenphp:1-php8.5-alpine`，以 digest 鎖定）：內建 Caddy 的 PHP 伺服器，一個容器、一個程序就能跑，和另外兩版一樣是「一個 api 容器 + 一個 db 容器」。
   - 考慮過的替代方案：nginx + php-fpm（最常見，但一個容器要跑兩個程序，或拆成兩個容器，設定較多）、Apache + mod_php（`php:apache` image，較重）。
   - 使用傳統模式（每個請求重新執行 `index.php`），不用 worker 模式：寫法最接近一般 PHP，不必處理請求之間殘留的狀態。每個需要 DB 的請求會新開一次連線（本機約 10ms），對範例專案足夠。
2. **不用框架**：路由寫在 `public/index.php`，驗證在 `src/ItemInput.php`，SQL 在 `src/ItemStore.php`，與另外兩版的結構對應。正式 image 沒有 composer 套件，只多裝 `pdo_pgsql`；composer 只用來在 CI 安裝 PHPUnit。
3. **建立資料表放在 entrypoint**：PHP 沒有「程式啟動時」可以執行的地方，所以容器啟動時先跑 `bin/migrate.php`（DB 未就緒會重試），成功後才 `exec frankenphp run`，行為與另外兩版相同（DB 還沒好時 api 不會變成 healthy）。
4. **與另外兩版一致的細節**：`PATH_BASE`（`/php`）自行去掉前綴、`Location` 帶回前綴、請求紀錄格式、名稱長度以 UTF-16 計算、時間戳以微秒 ISO 8601 輸出（與 .NET 相同精度）。
5. **Port 與對外網址**：主機 3002（容器內 8080），對外 `https://api-staging.heitang.info/php/...`，前端 Worker 以 `/api/php/*` 代轉。
6. **非 root 執行**：建立 `app` 使用者（uid 10001），Caddy 的資料目錄改為該使用者擁有。

## 後果

- 優點：三版可以並排比較；PHP 版和另外兩版一樣可以單獨部署、回滾、刪除。
- 代價：API 行為要在三處維護；主機多跑一組 api + db（再多一個 Postgres 容器）。
- 已知可接受的差異：時間戳精度（Node 毫秒、.NET 與 PHP 微秒）、`GET /` 的 `name`（`api-php`）。
