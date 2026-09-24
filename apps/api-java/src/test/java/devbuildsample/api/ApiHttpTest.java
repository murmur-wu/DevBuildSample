package devbuildsample.api;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpRequest.BodyPublishers;
import java.net.http.HttpResponse;
import java.net.http.HttpResponse.BodyHandlers;
import java.nio.charset.StandardCharsets;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;

/**
 * 不需要資料庫的 HTTP 行為：路徑前綴、錯誤訊息與狀態碼、請求紀錄格式（與另外五版一致）。
 * 啟動真正的 Tomcat（連線池要等第一次查詢才會連 DB，所以不需要資料庫）；CRUD 由 scripts/smoke-test.sh 驗收。
 */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT, properties = {"PATH_BASE=/java", "APP_VERSION=test"})
class ApiHttpTest {

    @LocalServerPort
    int port;

    private final HttpClient http = HttpClient.newHttpClient();

    private HttpResponse<String> send(String method, String path, String contentType, HttpRequest.BodyPublisher body)
            throws Exception {
        var builder = HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + port + path)).method(method, body);
        if (contentType != null) {
            builder.header("Content-Type", contentType);
        }
        return http.send(builder.build(), BodyHandlers.ofString());
    }

    private void expect(HttpResponse<String> res, int status, String body) {
        assertEquals(status + " " + body, res.statusCode() + " " + res.body(), res.request().uri().toString());
    }

    @ParameterizedTest
    @ValueSource(strings = {"/", "/java", "/java/"})
    void 根路徑回傳名稱與版本(String path) throws Exception {
        expect(send("GET", path, null, BodyPublishers.noBody()), 200, "{\"name\":\"api-java\",\"version\":\"test\"}");
    }

    @ParameterizedTest
    @CsvSource({"GET,/nope", "GET,/java/nope", "GET,/javax/", "GET,/javax/items", "POST,/health", "DELETE,/", "PUT,/java/health"})
    void 未知路徑與items以外用錯method都回404(String method, String path) throws Exception {
        expect(send(method, path, null, BodyPublishers.noBody()), 404, "{\"error\":\"not found\"}");
    }

    @ParameterizedTest
    @ValueSource(strings = {"/items", "/java/items", "/items/1", "/items/"})
    void items用錯method回405(String path) throws Exception {
        expect(send("PATCH", path, null, BodyPublishers.noBody()), 405, "{\"error\":\"method not allowed\"}");
    }

    @ParameterizedTest
    @ValueSource(strings = {"abc", "0", "-1", "2147483648"})
    void 不合法的id回404(String id) throws Exception {
        expect(send("GET", "/java/items/" + id, null, BodyPublishers.noBody()), 404, "{\"error\":\"item not found\"}");
    }

    @Test
    void 不合法的id優先於body檢查() throws Exception {
        expect(send("PUT", "/items/abc", "text/plain", BodyPublishers.ofString("x")), 404, "{\"error\":\"item not found\"}");
    }

    @Test
    void content_type不是json回415() throws Exception {
        expect(send("POST", "/items", "text/plain", BodyPublishers.ofString("{\"name\":\"x\"}")),
                415, "{\"error\":\"content-type must be application/json\"}");
    }

    @Test
    void body超過64KB回413_包含chunked() throws Exception {
        String big = "x".repeat(64 * 1024 + 1);
        expect(send("POST", "/items", "application/json", BodyPublishers.ofString(big)), 413, "{\"error\":\"body too large\"}");
        // ofInputStream 不帶 Content-Length，會以 chunked 傳送
        var chunked = BodyPublishers.ofInputStream(() -> new java.io.ByteArrayInputStream(big.getBytes(StandardCharsets.UTF_8)));
        expect(send("POST", "/items", "application/json", chunked), 413, "{\"error\":\"body too large\"}");
    }

    @ParameterizedTest
    @CsvSource(delimiter = '|', value = {
            "{not json|invalid JSON",
            "{} x|invalid JSON",
            "{\"name\":\"\"}|name is required",
            "{\"name\":\"x\",\"done\":\"yes\"}|done must be a boolean"})
    void 輸入錯誤回400(String body, String message) throws Exception {
        expect(send("POST", "/java/items", "application/json; charset=utf-8", BodyPublishers.ofString(body)),
                400, "{\"error\":\"" + message + "\"}");
    }

    @Test
    void 空的body與巢狀太深也是invalid_JSON() throws Exception {
        for (String body : List.of("", "[".repeat(5000))) {
            expect(send("POST", "/items", "application/json", BodyPublishers.ofString(body)), 400, "{\"error\":\"invalid JSON\"}");
        }
    }

    @Test
    void 請求紀錄格式() throws Exception {
        PrintStream original = System.out;
        var captured = new ByteArrayOutputStream();
        System.setOut(new PrintStream(captured, true, StandardCharsets.UTF_8));
        try {
            send("GET", "/java/items/abc?x=1", null, BodyPublishers.noBody());
            send("GET", "/java/nope", null, BodyPublishers.noBody());
        } finally {
            System.setOut(original);
        }
        String out = captured.toString(StandardCharsets.UTF_8);
        assertTrue(out.lines().anyMatch(l -> l.matches("GET /java/items/abc 404 \\d+ms")), out);
        assertTrue(out.lines().anyMatch(l -> l.matches("GET /java/nope 404 \\d+ms")), out);
    }
}
