package store

import (
	"errors"

	"github.com/syndtr/goleveldb/leveldb"
)

// ErrNotFound is returned by Get when the key does not exist.
var ErrNotFound = errors.New("key not found")

// Store wraps a LevelDB database.
type Store struct {
	db *leveldb.DB
}

// Open opens (or creates) a LevelDB database at path.
func Open(path string) (*Store, error) {
	db, err := leveldb.OpenFile(path, nil)
	if err != nil {
		return nil, err
	}
	return &Store{db: db}, nil
}

// Put stores value under key.
func (s *Store) Put(key, value []byte) error {
	return s.db.Put(key, value, nil)
}

// Get retrieves the value for key. Returns ErrNotFound if the key does not exist.
func (s *Store) Get(key []byte) ([]byte, error) {
	val, err := s.db.Get(key, nil)
	if errors.Is(err, leveldb.ErrNotFound) {
		return nil, ErrNotFound
	}
	return val, err
}

// Delete removes key. Deleting a non-existent key is a no-op.
func (s *Store) Delete(key []byte) error {
	return s.db.Delete(key, nil)
}

// Close closes the database. Must be called before process exit.
func (s *Store) Close() error {
	return s.db.Close()
}
