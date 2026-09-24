<?php

declare(strict_types=1);

namespace Api;

use PDO;

/**
 * items 資料表的存取；資料表與查詢條件與 Node 版相同。
 * 時間戳在 SQL 裡轉成 UTC 的 ISO 8601（微秒，與 .NET 版相同精度），不受連線時區影響。
 */
final class ItemStore
{
    private const COLUMNS = <<<'SQL'
        id, name, done,
        to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS created_at,
        to_char(updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS updated_at
        SQL;

    private ?PDO $pdo = null;

    /** 第一次查詢時才連線，/ 等不需要 DB 的請求不會連線。 */
    private function db(): PDO
    {
        return $this->pdo ??= new PDO(
            sprintf(
                'pgsql:host=%s;port=%s;dbname=%s;connect_timeout=2',
                getenv('DB_HOST') ?: 'db',
                getenv('DB_PORT') ?: '5432',
                getenv('POSTGRES_DB') ?: 'postgres',
            ),
            getenv('POSTGRES_USER') ?: 'postgres',
            getenv('POSTGRES_PASSWORD') ?: null,
            [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION],
        );
    }

    public function migrate(): void
    {
        $this->db()->exec(<<<'SQL'
            CREATE TABLE IF NOT EXISTS items (
              id         serial PRIMARY KEY,
              name       text NOT NULL,
              done       boolean NOT NULL DEFAULT false,
              created_at timestamptz NOT NULL DEFAULT now(),
              updated_at timestamptz NOT NULL DEFAULT now()
            )
            SQL);
    }

    public function ping(): void
    {
        $this->db()->query('SELECT 1');
    }

    /** @return list<array<string, mixed>> */
    public function list(): array
    {
        return $this->fetchAll('SELECT ' . self::COLUMNS . ' FROM items ORDER BY id');
    }

    /** @return ?array<string, mixed> */
    public function get(int $id): ?array
    {
        return $this->fetchAll('SELECT ' . self::COLUMNS . ' FROM items WHERE id = ?', [$id])[0] ?? null;
    }

    /** @return array<string, mixed> */
    public function create(ItemInput $input): array
    {
        return $this->fetchAll(
            'INSERT INTO items (name, done) VALUES (?, ?) RETURNING ' . self::COLUMNS,
            [$input->name, $input->done],
        )[0];
    }

    /** @return ?array<string, mixed> */
    public function update(int $id, ItemInput $input): ?array
    {
        return $this->fetchAll(
            'UPDATE items SET name = ?, done = ?, updated_at = now() WHERE id = ? RETURNING ' . self::COLUMNS,
            [$input->name, $input->done, $id],
        )[0] ?? null;
    }

    public function delete(int $id): bool
    {
        $stmt = $this->db()->prepare('DELETE FROM items WHERE id = ?');
        $stmt->execute([$id]);
        return $stmt->rowCount() > 0;
    }

    /**
     * @param list<mixed> $params
     * @return list<array<string, mixed>>
     */
    private function fetchAll(string $sql, array $params = []): array
    {
        $stmt = $this->db()->prepare($sql);
        foreach ($params as $i => $value) {
            $stmt->bindValue($i + 1, $value, match (true) {
                is_bool($value) => PDO::PARAM_BOOL,
                is_int($value) => PDO::PARAM_INT,
                default => PDO::PARAM_STR,
            });
        }
        $stmt->execute();
        return array_map(
            static fn (array $row): array => [
                'id' => (int) $row['id'],
                'name' => $row['name'],
                'done' => $row['done'] === true || $row['done'] === 't',   // 不用 (bool)：字串 'f' 會變成 true
                'created_at' => $row['created_at'],
                'updated_at' => $row['updated_at'],
            ],
            $stmt->fetchAll(PDO::FETCH_ASSOC),
        );
    }
}
