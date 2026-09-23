using Npgsql;

namespace Api;

public sealed record Item(int Id, string Name, bool Done, DateTime CreatedAt, DateTime UpdatedAt);

/// <summary>items 資料表的存取；SQL 與 Node 版相同。</summary>
public sealed class ItemStore(NpgsqlDataSource db)
{
    private const string Columns = "id, name, done, created_at, updated_at";

    public async Task MigrateAsync(CancellationToken ct = default)
    {
        await using var cmd = db.CreateCommand("""
            CREATE TABLE IF NOT EXISTS items (
              id         serial PRIMARY KEY,
              name       text NOT NULL,
              done       boolean NOT NULL DEFAULT false,
              created_at timestamptz NOT NULL DEFAULT now(),
              updated_at timestamptz NOT NULL DEFAULT now()
            )
            """);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task PingAsync(CancellationToken ct = default)
    {
        await using var cmd = db.CreateCommand("SELECT 1");
        await cmd.ExecuteScalarAsync(ct);
    }

    public async Task<List<Item>> ListAsync(CancellationToken ct = default)
    {
        await using var cmd = db.CreateCommand($"SELECT {Columns} FROM items ORDER BY id");
        return await ReadAllAsync(cmd, ct);
    }

    public async Task<Item?> GetAsync(int id, CancellationToken ct = default)
    {
        await using var cmd = db.CreateCommand($"SELECT {Columns} FROM items WHERE id = $1");
        cmd.Parameters.AddWithValue(id);
        return (await ReadAllAsync(cmd, ct)).FirstOrDefault();
    }

    public async Task<Item> CreateAsync(ItemInput input, CancellationToken ct = default)
    {
        await using var cmd = db.CreateCommand($"INSERT INTO items (name, done) VALUES ($1, $2) RETURNING {Columns}");
        cmd.Parameters.AddWithValue(input.Name);
        cmd.Parameters.AddWithValue(input.Done);
        return (await ReadAllAsync(cmd, ct))[0];
    }

    public async Task<Item?> UpdateAsync(int id, ItemInput input, CancellationToken ct = default)
    {
        await using var cmd = db.CreateCommand(
            $"UPDATE items SET name = $2, done = $3, updated_at = now() WHERE id = $1 RETURNING {Columns}");
        cmd.Parameters.AddWithValue(id);
        cmd.Parameters.AddWithValue(input.Name);
        cmd.Parameters.AddWithValue(input.Done);
        return (await ReadAllAsync(cmd, ct)).FirstOrDefault();
    }

    public async Task<bool> DeleteAsync(int id, CancellationToken ct = default)
    {
        await using var cmd = db.CreateCommand("DELETE FROM items WHERE id = $1");
        cmd.Parameters.AddWithValue(id);
        return await cmd.ExecuteNonQueryAsync(ct) > 0;
    }

    private static async Task<List<Item>> ReadAllAsync(NpgsqlCommand cmd, CancellationToken ct)
    {
        var items = new List<Item>();
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            items.Add(new Item(
                reader.GetInt32(0),
                reader.GetString(1),
                reader.GetBoolean(2),
                reader.GetDateTime(3),
                reader.GetDateTime(4)));
        }
        return items;
    }
}
