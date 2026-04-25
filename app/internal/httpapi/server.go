package httpapi

import (
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	"github.com/CopyPasteFail/stateful-k8s-recovery-lab/app/internal/store"
)

// Server is an HTTP server wrapping the key-value store.
type Server struct {
	*http.Server
	st         *store.Store
	ready      atomic.Bool
	requests   *prometheus.CounterVec
	durations  *prometheus.HistogramVec
	dbErrors   *prometheus.CounterVec
	readyGauge prometheus.Gauge
}

const rootEndpointDescription = "API-only LevelDB-backed key-value service."

// NewServer constructs a Server bound to addr. The caller must call
// ListenAndServe (or Shutdown in tests).
func NewServer(st *store.Store, addr string) *Server {
	reg := prometheus.NewRegistry()

	requests := prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "http_requests_total",
		Help: "Total HTTP requests by method, path, and status code.",
	}, []string{"method", "path", "status_code"})

	durations := prometheus.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "http_request_duration_seconds",
		Help:    "HTTP request latency in seconds.",
		Buckets: prometheus.DefBuckets,
	}, []string{"method", "path"})

	dbErrors := prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "leveldb_errors_total",
		Help: "Total LevelDB operation errors by type.",
	}, []string{"operation"})

	readyGauge := prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "app_ready",
		Help: "1 when the application is ready (database open), 0 otherwise.",
	})

	reg.MustRegister(requests, durations, dbErrors, readyGauge)

	s := &Server{
		st:         st,
		requests:   requests,
		durations:  durations,
		dbErrors:   dbErrors,
		readyGauge: readyGauge,
	}
	s.SetReady(true)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /", s.handleRoot)
	mux.HandleFunc("PUT /kv/{key}", s.handlePut)
	mux.HandleFunc("GET /kv/{key}", s.handleGet)
	mux.HandleFunc("DELETE /kv/{key}", s.handleDelete)
	mux.HandleFunc("GET /healthz", s.handleHealthz)
	mux.HandleFunc("GET /readyz", s.handleReadyz)
	mux.Handle("GET /metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{}))

	s.Server = &http.Server{
		Addr:         addr,
		Handler:      s.instrument(mux),
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	return s
}

type rootResponse struct {
	Description string   `json:"description"`
	Endpoints   []string `json:"endpoints"`
}

// handleRoot returns a short JSON description of the service and the useful
// endpoints for local demo users.
func (s *Server) handleRoot(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)

	response := rootResponse{
		Description: rootEndpointDescription,
		Endpoints: []string{
			"GET /healthz",
			"GET /readyz",
			"GET /metrics",
			"PUT /kv/{key}",
			"GET /kv/{key}",
			"DELETE /kv/{key}",
		},
	}

	if err := json.NewEncoder(w).Encode(response); err != nil {
		log.Printf("root: write response: %v", err)
	}
}

// SetReady marks the server as ready or not ready. It updates both the
// in-memory flag checked by /readyz and the app_ready Prometheus gauge.
// Call SetReady(false) before Shutdown to drop readiness before draining.
func (s *Server) SetReady(v bool) {
	s.ready.Store(v)
	if v {
		s.readyGauge.Set(1)
	} else {
		s.readyGauge.Set(0)
	}
}

// responseWriter captures the status code written by a handler.
type responseWriter struct {
	http.ResponseWriter
	status int
}

func (rw *responseWriter) WriteHeader(status int) {
	rw.status = status
	rw.ResponseWriter.WriteHeader(status)
}

// instrument wraps a handler with request counting and duration tracking.
// Paths under /kv/ are normalised to /kv/{key} to prevent label cardinality explosion.
func (s *Server) instrument(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rw := &responseWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rw, r)

		path := r.URL.Path
		if strings.HasPrefix(path, "/kv/") {
			path = "/kv/{key}"
		}
		code := strconv.Itoa(rw.status)
		s.requests.WithLabelValues(r.Method, path, code).Inc()
		s.durations.WithLabelValues(r.Method, path).Observe(time.Since(start).Seconds())
	})
}

func (s *Server) handlePut(w http.ResponseWriter, r *http.Request) {
	key := r.PathValue("key")
	if key == "" {
		http.Error(w, "key must not be empty", http.StatusBadRequest)
		return
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "failed to read request body", http.StatusBadRequest)
		return
	}

	if err := s.st.Put([]byte(key), body); err != nil {
		log.Printf("PUT %s: %v", key, err)
		s.dbErrors.WithLabelValues("put").Inc()
		http.Error(w, "store error", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleGet(w http.ResponseWriter, r *http.Request) {
	key := r.PathValue("key")

	val, err := s.st.Get([]byte(key))
	if errors.Is(err, store.ErrNotFound) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if err != nil {
		log.Printf("GET %s: %v", key, err)
		s.dbErrors.WithLabelValues("get").Inc()
		http.Error(w, "store error", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/octet-stream")
	if _, err := w.Write(val); err != nil {
		log.Printf("GET %s: write response: %v", key, err)
	}
}

func (s *Server) handleDelete(w http.ResponseWriter, r *http.Request) {
	key := r.PathValue("key")

	if err := s.st.Delete([]byte(key)); err != nil {
		log.Printf("DELETE %s: %v", key, err)
		s.dbErrors.WithLabelValues("delete").Inc()
		http.Error(w, "store error", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	if _, err := w.Write([]byte("ok\n")); err != nil {
		log.Printf("healthz: write: %v", err)
	}
}

func (s *Server) handleReadyz(w http.ResponseWriter, r *http.Request) {
	if !s.ready.Load() {
		http.Error(w, "not ready", http.StatusServiceUnavailable)
		return
	}
	w.WriteHeader(http.StatusOK)
	if _, err := w.Write([]byte("ok\n")); err != nil {
		log.Printf("readyz: write: %v", err)
	}
}
