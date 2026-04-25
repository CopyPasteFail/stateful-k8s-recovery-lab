package httpapi_test

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/CopyPasteFail/stateful-k8s-recovery-lab/app/internal/httpapi"
	"github.com/CopyPasteFail/stateful-k8s-recovery-lab/app/internal/store"
)

func newTestServer(t *testing.T) *httpapi.Server {
	t.Helper()
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	return httpapi.NewServer(st, ":0")
}

func do(srv *httpapi.Server, method, path, body string) *httptest.ResponseRecorder {
	var rb io.Reader
	if body != "" {
		rb = strings.NewReader(body)
	}
	req := httptest.NewRequest(method, path, rb)
	w := httptest.NewRecorder()
	srv.Handler.ServeHTTP(w, req)
	return w
}

func TestPutGetDeleteCycle(t *testing.T) {
	srv := newTestServer(t)

	// PUT
	w := do(srv, http.MethodPut, "/kv/hello", "world")
	if w.Code != http.StatusNoContent {
		t.Fatalf("PUT status = %d, want %d", w.Code, http.StatusNoContent)
	}

	// GET — value must match
	w = do(srv, http.MethodGet, "/kv/hello", "")
	if w.Code != http.StatusOK {
		t.Fatalf("GET status = %d, want %d", w.Code, http.StatusOK)
	}
	if got := w.Body.String(); got != "world" {
		t.Errorf("GET body = %q, want %q", got, "world")
	}

	// DELETE
	w = do(srv, http.MethodDelete, "/kv/hello", "")
	if w.Code != http.StatusNoContent {
		t.Fatalf("DELETE status = %d, want %d", w.Code, http.StatusNoContent)
	}

	// GET after DELETE — must be 404
	w = do(srv, http.MethodGet, "/kv/hello", "")
	if w.Code != http.StatusNotFound {
		t.Fatalf("GET after DELETE status = %d, want %d", w.Code, http.StatusNotFound)
	}
}

func TestGetMissing(t *testing.T) {
	srv := newTestServer(t)

	w := do(srv, http.MethodGet, "/kv/nosuchkey", "")
	if w.Code != http.StatusNotFound {
		t.Errorf("GET missing status = %d, want %d", w.Code, http.StatusNotFound)
	}
}

func TestPutIdempotent(t *testing.T) {
	srv := newTestServer(t)

	do(srv, http.MethodPut, "/kv/k", "first")
	do(srv, http.MethodPut, "/kv/k", "second")

	w := do(srv, http.MethodGet, "/kv/k", "")
	if w.Code != http.StatusOK {
		t.Fatalf("GET status = %d", w.Code)
	}
	if got := w.Body.String(); got != "second" {
		t.Errorf("GET after overwrite = %q, want %q", got, "second")
	}
}

func TestDeleteIdempotent(t *testing.T) {
	srv := newTestServer(t)

	// DELETE a key that was never written must not error.
	w := do(srv, http.MethodDelete, "/kv/ghost", "")
	if w.Code != http.StatusNoContent {
		t.Errorf("DELETE nonexistent status = %d, want %d", w.Code, http.StatusNoContent)
	}
}

func TestHealthz(t *testing.T) {
	srv := newTestServer(t)

	w := do(srv, http.MethodGet, "/healthz", "")
	if w.Code != http.StatusOK {
		t.Errorf("healthz status = %d, want %d", w.Code, http.StatusOK)
	}
}

func TestReadyz(t *testing.T) {
	srv := newTestServer(t)

	w := do(srv, http.MethodGet, "/readyz", "")
	if w.Code != http.StatusOK {
		t.Errorf("readyz status = %d, want %d", w.Code, http.StatusOK)
	}
}

func TestReadyzNotReady(t *testing.T) {
	srv := newTestServer(t)
	srv.SetReady(false)

	w := do(srv, http.MethodGet, "/readyz", "")
	if w.Code != http.StatusServiceUnavailable {
		t.Errorf("readyz after SetReady(false) = %d, want %d", w.Code, http.StatusServiceUnavailable)
	}
}

func TestMetricsEndpoint(t *testing.T) {
	srv := newTestServer(t)

	// Populate at least one counter before scraping; the /metrics handler
	// serialises the registry at the moment it runs, so prior activity is needed.
	do(srv, http.MethodGet, "/healthz", "")

	w := do(srv, http.MethodGet, "/metrics", "")
	if w.Code != http.StatusOK {
		t.Errorf("metrics status = %d, want %d", w.Code, http.StatusOK)
	}
	if !strings.Contains(w.Body.String(), "http_requests_total") {
		t.Error("metrics body missing http_requests_total")
	}
}
