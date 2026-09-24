package main

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"
)

// 不需要資料庫的 HTTP 行為：路徑前綴、錯誤訊息與狀態碼、請求紀錄格式（與另外四版一致）。
// 需要資料庫的部分（CRUD）由 scripts/smoke-test.sh 驗收。

func newTestServer() (*server, *bytes.Buffer) {
	var logs bytes.Buffer
	return &server{store: nil, version: "test", pathBase: "/go", logOut: &logs}, &logs
}

func do(s *server, method, path, contentType string, body io.Reader) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, body)
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	rec := httptest.NewRecorder()
	s.ServeHTTP(rec, req)
	return rec
}

func expect(t *testing.T, rec *httptest.ResponseRecorder, status int, body string) {
	t.Helper()
	if rec.Code != status || rec.Body.String() != body {
		t.Fatalf("got %d %s, want %d %s", rec.Code, rec.Body.String(), status, body)
	}
}

func TestRoot(t *testing.T) {
	s, _ := newTestServer()
	for _, path := range []string{"/", "/go", "/go/"} {
		expect(t, do(s, "GET", path, "", nil), 200, `{"name":"api-go","version":"test"}`)
	}
}

func TestNotFound(t *testing.T) {
	s, _ := newTestServer()
	for _, c := range []struct{ method, path string }{
		{"GET", "/nope"}, {"GET", "/go/nope"}, {"GET", "/gox/"}, {"GET", "/gox/items"},
		{"POST", "/health"}, {"DELETE", "/"}, {"PUT", "/go/health"},
	} {
		expect(t, do(s, c.method, c.path, "", nil), 404, `{"error":"not found"}`)
	}
}

func TestMethodNotAllowed(t *testing.T) {
	s, _ := newTestServer()
	for _, path := range []string{"/items", "/go/items", "/items/1", "/items/"} {
		expect(t, do(s, "PATCH", path, "", nil), 405, `{"error":"method not allowed"}`)
	}
}

func TestInvalidID(t *testing.T) {
	s, _ := newTestServer()
	for _, id := range []string{"abc", "0", "-1", "2147483648", "%31"} {
		expect(t, do(s, "GET", "/go/items/"+id, "", nil), 404, `{"error":"item not found"}`)
	}
	// 不合法的 id 優先於 body 檢查
	expect(t, do(s, "PUT", "/items/abc", "text/plain", strings.NewReader("x")), 404, `{"error":"item not found"}`)
}

func TestBodyErrors(t *testing.T) {
	s, _ := newTestServer()
	expect(t, do(s, "POST", "/items", "text/plain", strings.NewReader(`{"name":"x"}`)),
		415, `{"error":"content-type must be application/json"}`)
	expect(t, do(s, "POST", "/items", "application/json", strings.NewReader(strings.Repeat("x", 64*1024+1))),
		413, `{"error":"body too large"}`)

	// Content-Length 未知（chunked）時邊讀邊算
	req := httptest.NewRequest("POST", "/items", io.MultiReader(strings.NewReader(strings.Repeat("x", 70000))))
	req.ContentLength = -1
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	s.ServeHTTP(rec, req)
	expect(t, rec, 413, `{"error":"body too large"}`)

	for body, msg := range map[string]string{
		`{not json`:                 "invalid JSON",
		``:                          "invalid JSON",
		`{} x`:                      "invalid JSON",
		strings.Repeat("[", 20000):  "invalid JSON",
		`{"name":""}`:               "name is required",
		`{"name":"x","done":"yes"}`: "done must be a boolean",
	} {
		expect(t, do(s, "POST", "/go/items", "application/json; charset=utf-8", strings.NewReader(body)),
			400, `{"error":"`+msg+`"}`)
	}
}

func TestRequestLog(t *testing.T) {
	s, logs := newTestServer()
	do(s, "GET", "/go/items/abc?x=1", "", nil)
	do(s, "GET", "/go/nope", "", nil)
	lines := strings.Split(strings.TrimSpace(logs.String()), "\n")
	patterns := []string{`^GET /go/items/abc 404 \d+ms$`, `^GET /go/nope 404 \d+ms$`}
	if len(lines) != len(patterns) {
		t.Fatalf("got %q", lines)
	}
	for i, p := range patterns {
		if !regexp.MustCompile(p).MatchString(lines[i]) {
			t.Errorf("line %d: %q does not match %s", i, lines[i], p)
		}
	}
}

func TestResponseIsJSON(t *testing.T) {
	s, _ := newTestServer()
	rec := do(s, "GET", "/nope", "", nil)
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Fatalf("content-type %q", ct)
	}
	if rec.Code != http.StatusNotFound {
		t.Fatal(rec.Code)
	}
}
