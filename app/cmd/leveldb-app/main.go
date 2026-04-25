package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/CopyPasteFail/stateful-k8s-recovery-lab/app/internal/httpapi"
	"github.com/CopyPasteFail/stateful-k8s-recovery-lab/app/internal/store"
)

func main() {
	dataDir := os.Getenv("DATA_DIR")
	if dataDir == "" {
		dataDir = "/data/leveldb"
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		log.Fatalf("create data dir %s: %v", dataDir, err)
	}

	st, err := store.Open(dataDir)
	if err != nil {
		log.Fatalf("open store %s: %v", dataDir, err)
	}
	defer func() {
		if err := st.Close(); err != nil {
			log.Printf("close store: %v", err)
		}
	}()

	srv := httpapi.NewServer(st, ":"+port)

	go func() {
		log.Printf("listening on :%s  data=%s", port, dataDir)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("server: %v", err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Println("shutting down...")
	srv.SetReady(false) // stop readyz before draining in-flight requests

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		log.Printf("shutdown: %v", err)
	}
	log.Println("stopped")
}
