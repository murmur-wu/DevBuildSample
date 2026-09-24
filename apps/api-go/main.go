// 與 Node、.NET、PHP、Python 版相同的 API：/health、/、/items CRUD；欄位名稱、狀態碼、錯誤訊息一致，
// 以便共用 scripts/smoke-test.sh 驗收。只用標準函式庫的 net/http，路由與 Node 版一樣自己比對路徑。
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const maxBodyBytes = 64 * 1024

type httpError struct {
	status  int
	message string
}

func (e *httpError) Error() string { return e.message }

var itemsPath = regexp.MustCompile(`^/items(?:/([^/]+))?/?$`)

// server 處理所有請求；store 只在通過驗證、真的需要資料庫時才會用到（單元測試可以傳 nil）。
type server struct {
	store    *Store
	version  string
	pathBase string
	logOut   io.Writer
}

// ServeHTTP：處理路徑前綴並輸出請求紀錄，再交給 route。
func (s *server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
	// 紀錄用原始路徑（未解碼、不含 query string），與 Node 版相同
	fullPath := r.URL.EscapedPath()
	base, path := "", fullPath
	// 對外經 tunnel 時網址帶前綴（例如 /go），cloudflared 不會去掉，所以在這裡去掉；
	// 沒帶前綴的請求（本機、healthcheck）照常處理。與 Node 版、ASP.NET Core 的 UsePathBase 行為相同。
	if s.pathBase != "" && (fullPath == s.pathBase || strings.HasPrefix(fullPath, s.pathBase+"/")) {
		base, path = s.pathBase, strings.TrimPrefix(fullPath, s.pathBase)
		if path == "" {
			path = "/"
		}
	}

	defer func() {
		if p := recover(); p != nil {
			log.Printf("panic: %v", p)
			writeJSON(rec, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		}
		// 請求紀錄：每個請求一行「方法 路徑 狀態碼 耗時」，例如 `POST /go/items 201 4ms`（格式與另外四版相同）。
		// 成功的 /health 不記（docker healthcheck 每 10 秒打一次，會洗版）。
		if rec.status == http.StatusOK && path == "/health" {
			return
		}
		fmt.Fprintf(s.logOut, "%s %s %d %dms\n", r.Method, fullPath, rec.status, time.Since(start).Milliseconds())
	}()

	if err := s.route(rec, r, path, base); err != nil {
		var he *httpError
		if errors.As(err, &he) {
			writeJSON(rec, he.status, map[string]string{"error": he.message})
			return
		}
		log.Printf("error: %v", err)
		writeJSON(rec, http.StatusInternalServerError, map[string]string{"error": "internal error"})
	}
}

func (s *server) route(w http.ResponseWriter, r *http.Request, path, base string) error {
	ctx := r.Context()
	switch {
	case r.Method == http.MethodGet && path == "/health":
		ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
		defer cancel()
		if err := s.store.Ping(ctx); err != nil {
			// 用 struct 而不是 map：map 會依字母排序，欄位順序就和其他版不同
			writeJSON(w, http.StatusServiceUnavailable, struct {
				Status string `json:"status"`
				DB     string `json:"db"`
			}{"error", err.Error()})
			return nil
		}
		writeJSON(w, http.StatusOK, struct {
			Status  string `json:"status"`
			DB      string `json:"db"`
			Version string `json:"version"`
		}{"ok", "ok", s.version})
		return nil
	case r.Method == http.MethodGet && path == "/":
		writeJSON(w, http.StatusOK, struct {
			Name    string `json:"name"`
			Version string `json:"version"`
		}{"api-go", s.version})
		return nil
	}

	m := itemsPath.FindStringSubmatch(path)
	if m == nil {
		return &httpError{http.StatusNotFound, "not found"}
	}
	if m[1] == "" {
		return s.handleCollection(w, r, base)
	}
	return s.handleItem(w, r, m[1])
}

func (s *server) handleCollection(w http.ResponseWriter, r *http.Request, base string) error {
	switch r.Method {
	case http.MethodGet:
		items, err := s.store.List(r.Context())
		if err != nil {
			return err
		}
		writeJSON(w, http.StatusOK, items)
		return nil
	case http.MethodPost:
		in, err := readItemInput(w, r)
		if err != nil {
			return err
		}
		item, err := s.store.Create(r.Context(), in)
		if err != nil {
			return err
		}
		w.Header().Set("Location", base+"/items/"+strconv.Itoa(item.ID))
		writeJSON(w, http.StatusCreated, item)
		return nil
	}
	return &httpError{http.StatusMethodNotAllowed, "method not allowed"}
}

func (s *server) handleItem(w http.ResponseWriter, r *http.Request, rawID string) error {
	id, ok := parseID(rawID)
	if !ok {
		return &httpError{http.StatusNotFound, "item not found"}
	}
	var item *Item
	var err error
	switch r.Method {
	case http.MethodGet:
		item, err = s.store.Get(r.Context(), id)
	case http.MethodPut:
		in, readErr := readItemInput(w, r)
		if readErr != nil {
			return readErr
		}
		item, err = s.store.Update(r.Context(), id, in)
	case http.MethodDelete:
		deleted, err := s.store.Delete(r.Context(), id)
		if err != nil {
			return err
		}
		if !deleted {
			return &httpError{http.StatusNotFound, "item not found"}
		}
		w.WriteHeader(http.StatusNoContent)
		return nil
	default:
		return &httpError{http.StatusMethodNotAllowed, "method not allowed"}
	}
	if err != nil {
		return err
	}
	if item == nil {
		return &httpError{http.StatusNotFound, "item not found"}
	}
	writeJSON(w, http.StatusOK, item)
	return nil
}

func readItemInput(w http.ResponseWriter, r *http.Request) (ItemInput, error) {
	if !strings.HasPrefix(r.Header.Get("Content-Type"), "application/json") {
		return ItemInput{}, &httpError{http.StatusUnsupportedMediaType, "content-type must be application/json"}
	}
	// 先看 Content-Length；沒有的話（chunked）由 MaxBytesReader 邊讀邊算，超過就停
	if r.ContentLength > maxBodyBytes {
		return ItemInput{}, &httpError{http.StatusRequestEntityTooLarge, "body too large"}
	}
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBodyBytes))
	if err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			return ItemInput{}, &httpError{http.StatusRequestEntityTooLarge, "body too large"}
		}
		return ItemInput{}, err
	}
	var body any
	if err := json.Unmarshal(raw, &body); err != nil {
		return ItemInput{}, &httpError{http.StatusBadRequest, "invalid JSON"}
	}
	in, msg := parseItemInput(body)
	if msg != "" {
		return ItemInput{}, &httpError{http.StatusBadRequest, msg}
	}
	return in, nil
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false) // 與 Node 的 JSON.stringify 一樣，不把 < > & 轉成 < 等
	if err := enc.Encode(body); err != nil {
		log.Printf("encode: %v", err)
		status, buf = http.StatusInternalServerError, *bytes.NewBufferString(`{"error":"internal error"}`)
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	w.Write(bytes.TrimSuffix(buf.Bytes(), []byte("\n")))
}

// statusRecorder 記下最後的狀態碼給請求紀錄用
type statusRecorder struct {
	http.ResponseWriter
	status      int
	wroteHeader bool
}

func (r *statusRecorder) WriteHeader(status int) {
	if r.wroteHeader {
		return
	}
	r.status, r.wroteHeader = status, true
	r.ResponseWriter.WriteHeader(status)
}

func (r *statusRecorder) Write(b []byte) (int, error) {
	if !r.wroteHeader {
		r.WriteHeader(http.StatusOK)
	}
	return r.ResponseWriter.Write(b)
}

func main() {
	log.SetFlags(0)
	// 容器內是 PID 1：要自己處理 SIGTERM，docker stop 才能立刻結束（包含還在等 DB 的時候）
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()

	store, err := newStore()
	if err != nil {
		log.Fatalf("db config: %v", err)
	}
	defer store.Close()

	// DB 可能比 api 晚就緒（例如主機重開機），migration 失敗就重試；成功前不開始接受請求
	for attempt := 1; ; attempt++ {
		mctx, cancel := context.WithTimeout(ctx, 3*time.Second)
		err := store.Migrate(mctx)
		cancel()
		if err == nil {
			break
		}
		if ctx.Err() != nil {
			return
		}
		log.Printf("migration failed (attempt %d): %v", attempt, err)
		select {
		case <-ctx.Done():
			return
		case <-time.After(time.Duration(min(attempt, 10)) * time.Second):
		}
	}

	srv := &http.Server{
		Addr: ":8080",
		Handler: &server{
			store:    store,
			version:  env("APP_VERSION", "dev"),
			pathBase: strings.TrimRight(os.Getenv("PATH_BASE"), "/"),
			logOut:   os.Stdout,
		},
		ReadHeaderTimeout: 10 * time.Second,
	}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		srv.Shutdown(shutdownCtx)
	}()
	log.Printf("api listening on :8080")
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
