package devbuildsample.api;

import java.util.List;
import java.util.Optional;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.stereotype.Repository;

/**
 * items 資料表的存取；資料表與查詢條件與另外五版相同。
 * 時間戳在 SQL 裡轉成 UTC 的 ISO 8601（微秒，與 .NET、PHP、Python、Go 版相同精度）。
 */
@Repository
public class ItemStore {

    static final String SCHEMA = """
            CREATE TABLE IF NOT EXISTS items (
              id         serial PRIMARY KEY,
              name       text NOT NULL,
              done       boolean NOT NULL DEFAULT false,
              created_at timestamptz NOT NULL DEFAULT now(),
              updated_at timestamptz NOT NULL DEFAULT now()
            )""";

    private static final String COLUMNS = """
            id, name, done,
            to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS created_at,
            to_char(updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS updated_at""";

    private static final RowMapper<Item> ROW = (rs, n) -> new Item(
            rs.getInt("id"), rs.getString("name"), rs.getBoolean("done"),
            rs.getString("created_at"), rs.getString("updated_at"));

    private final JdbcTemplate jdbc;

    public ItemStore(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public void ping() {
        jdbc.queryForObject("SELECT 1", Integer.class);
    }

    public List<Item> list() {
        return jdbc.query("SELECT " + COLUMNS + " FROM items ORDER BY id", ROW);
    }

    public Optional<Item> get(int id) {
        return first(jdbc.query("SELECT " + COLUMNS + " FROM items WHERE id = ?", ROW, id));
    }

    public Item create(ItemInput in) {
        return jdbc.queryForObject(
                "INSERT INTO items (name, done) VALUES (?, ?) RETURNING " + COLUMNS, ROW, in.name(), in.done());
    }

    public Optional<Item> update(int id, ItemInput in) {
        return first(jdbc.query(
                "UPDATE items SET name = ?, done = ?, updated_at = now() WHERE id = ? RETURNING " + COLUMNS,
                ROW, in.name(), in.done(), id));
    }

    public boolean delete(int id) {
        return jdbc.update("DELETE FROM items WHERE id = ?", id) > 0;
    }

    private static Optional<Item> first(List<Item> rows) {
        return rows.stream().findFirst();
    }

    /** JSON 欄位為 snake_case（application.properties 設定 Jackson 的命名規則）。 */
    public record Item(int id, String name, boolean done, String createdAt, String updatedAt) {}
}
