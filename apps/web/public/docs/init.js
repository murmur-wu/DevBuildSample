// Swagger UI 設定：讀取同網域的 /openapi.yaml；servers（/api/node、/api/dotnet、/api/php、/api/py、/api/go、/api/java）是相對網址，
// 所以「Try it out」會打到同一個 Worker，由它代轉到後端，沒有跨網域問題。
window.ui = SwaggerUIBundle({
  url: '/openapi.yaml',
  dom_id: '#swagger-ui',
  deepLinking: true,
  tryItOutEnabled: false,
  displayRequestDuration: true,
});
