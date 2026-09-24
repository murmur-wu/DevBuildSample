package main

import (
	"context"
	"errors"
	"fmt"
	"os"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Item 的時間戳在 SQL 裡轉成 UTC 的 ISO 8601（微秒，與 .NET、PHP、Python 版相同精度）。
type Item struct {
	ID        int    `json:"id"`
	Name      string `json:"name"`
	Done      bool   `json:"done"`
	CreatedAt string `json:"created_at"`
	UpdatedAt string `json:"updated_at"`
}

const itemColumns = `id, name, done,
	to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
	to_char(updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')`

const schema = `
	CREATE TABLE IF NOT EXISTS items (
	  id         serial PRIMARY KEY,
	  name       text NOT NULL,
	  done       boolean NOT NULL DEFAULT false,
	  created_at timestamptz NOT NULL DEFAULT now(),
	  updated_at timestamptz NOT NULL DEFAULT now()
	)`

// Store 是 items 資料表的存取；資料表與查詢條件與另外四版相同。
type Store struct {
	pool *pgxpool.Pool
}

func newStore() (*Store, error) {
	cfg, err := pgxpool.ParseConfig("connect_timeout=2")
	if err != nil {
		return nil, err
	}
	// 直接設定欄位、不組連線字串，密碼含特殊字元時不用跳脫
	cfg.ConnConfig.Host = env("DB_HOST", "db")
	cfg.ConnConfig.Database = env("POSTGRES_DB", "postgres")
	if _, err := fmt.Sscan(env("DB_PORT", "5432"), &cfg.ConnConfig.Port); err != nil {
		return nil, fmt.Errorf("DB_PORT: %w", err)
	}
	cfg.ConnConfig.User = env("POSTGRES_USER", "postgres")
	cfg.ConnConfig.Password = os.Getenv("POSTGRES_PASSWORD")
	cfg.MaxConns = 5
	// pgxpool 在借出閒置超過 1 秒的連線前會先 ping，DB 重啟後不會拿到失效的連線
	pool, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		return nil, err
	}
	return &Store{pool: pool}, nil
}

func (s *Store) Close() { s.pool.Close() }

func (s *Store) Migrate(ctx context.Context) error {
	_, err := s.pool.Exec(ctx, schema)
	return err
}

func (s *Store) Ping(ctx context.Context) error {
	_, err := s.pool.Exec(ctx, "SELECT 1")
	return err
}

func (s *Store) List(ctx context.Context) ([]Item, error) {
	rows, err := s.pool.Query(ctx, "SELECT "+itemColumns+" FROM items ORDER BY id")
	if err != nil {
		return nil, err
	}
	items, err := pgx.CollectRows(rows, scanItem)
	if items == nil {
		items = []Item{} // 空列表輸出 []，不是 null
	}
	return items, err
}

func (s *Store) Get(ctx context.Context, id int) (*Item, error) {
	return s.one(ctx, "SELECT "+itemColumns+" FROM items WHERE id = $1", id)
}

func (s *Store) Create(ctx context.Context, in ItemInput) (*Item, error) {
	return s.one(ctx, "INSERT INTO items (name, done) VALUES ($1, $2) RETURNING "+itemColumns, in.Name, in.Done)
}

func (s *Store) Update(ctx context.Context, id int, in ItemInput) (*Item, error) {
	return s.one(ctx,
		"UPDATE items SET name = $2, done = $3, updated_at = now() WHERE id = $1 RETURNING "+itemColumns,
		id, in.Name, in.Done)
}

func (s *Store) Delete(ctx context.Context, id int) (bool, error) {
	tag, err := s.pool.Exec(ctx, "DELETE FROM items WHERE id = $1", id)
	return tag.RowsAffected() > 0, err
}

// one 回傳單筆；找不到時回傳 nil, nil
func (s *Store) one(ctx context.Context, sql string, args ...any) (*Item, error) {
	rows, err := s.pool.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	item, err := pgx.CollectOneRow(rows, scanItem)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &item, nil
}

func scanItem(row pgx.CollectableRow) (Item, error) {
	var it Item
	err := row.Scan(&it.ID, &it.Name, &it.Done, &it.CreatedAt, &it.UpdatedAt)
	return it, err
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
