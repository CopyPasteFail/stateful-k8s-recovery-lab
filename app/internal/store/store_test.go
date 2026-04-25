package store_test

import (
	"errors"
	"testing"

	"github.com/CopyPasteFail/stateful-k8s-recovery-lab/app/internal/store"
)

func openTemp(t *testing.T) *store.Store {
	t.Helper()
	s, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

func TestPutGet(t *testing.T) {
	s := openTemp(t)

	if err := s.Put([]byte("k"), []byte("v")); err != nil {
		t.Fatalf("Put: %v", err)
	}
	got, err := s.Get([]byte("k"))
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if string(got) != "v" {
		t.Errorf("Get = %q, want %q", got, "v")
	}
}

func TestGetMissing(t *testing.T) {
	s := openTemp(t)

	_, err := s.Get([]byte("missing"))
	if !errors.Is(err, store.ErrNotFound) {
		t.Errorf("Get missing = %v, want ErrNotFound", err)
	}
}

func TestDelete(t *testing.T) {
	s := openTemp(t)

	if err := s.Put([]byte("k"), []byte("v")); err != nil {
		t.Fatalf("Put: %v", err)
	}
	if err := s.Delete([]byte("k")); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	_, err := s.Get([]byte("k"))
	if !errors.Is(err, store.ErrNotFound) {
		t.Errorf("Get after Delete = %v, want ErrNotFound", err)
	}
}

func TestDeleteIdempotent(t *testing.T) {
	s := openTemp(t)

	// Deleting a key that never existed must not error.
	if err := s.Delete([]byte("nonexistent")); err != nil {
		t.Errorf("Delete nonexistent = %v, want nil", err)
	}
}

func TestPutOverwrite(t *testing.T) {
	s := openTemp(t)

	if err := s.Put([]byte("k"), []byte("v1")); err != nil {
		t.Fatalf("Put v1: %v", err)
	}
	if err := s.Put([]byte("k"), []byte("v2")); err != nil {
		t.Fatalf("Put v2: %v", err)
	}
	got, err := s.Get([]byte("k"))
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if string(got) != "v2" {
		t.Errorf("Get = %q, want %q", got, "v2")
	}
}
