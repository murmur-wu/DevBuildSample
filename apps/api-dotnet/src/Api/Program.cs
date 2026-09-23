using System.Text.Json;
using Api;
using Npgsql;

// 與 Node 版（apps/api）相同的 API：/health、/、/items CRUD；欄位名稱、狀態碼、錯誤訊息一致，
// 以便共用 scripts/smoke-test.sh 驗收。
const int MaxBodyBytes = 64 * 1024;

var builder = WebApplication.CreateBuilder(args);
var version = Environment.GetEnvironmentVariable("APP_VERSION") ?? "dev";

var connection = new NpgsqlConnectionStringBuilder
{
    Host = Environment.GetEnvironmentVariable("DB_HOST") ?? "db",
    Port = int.Parse(Environment.GetEnvironmentVariable("DB_PORT") ?? "5432"),
    Username = Environment.GetEnvironmentVariable("POSTGRES_USER") ?? "postgres",
    Password = Environment.GetEnvironmentVariable("POSTGRES_PASSWORD"),
    Database = Environment.GetEnvironmentVariable("POSTGRES_DB") ?? "postgres",
    MaxPoolSize = 5,
    Timeout = 2,
};
builder.Services.AddSingleton(NpgsqlDataSource.Create(connection.ConnectionString));
builder.Services.AddSingleton<ItemStore>();
builder.Services.ConfigureHttpJsonOptions(o =>
    o.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower);

var app = builder.Build();

app.UseExceptionHandler(e => e.Run(ctx =>
    Error(500, "internal error").ExecuteAsync(ctx)));

// 對外經 tunnel 時網址帶前綴（例如 /dotnet），cloudflared 不會去掉，所以用 UsePathBase 去掉；
// 沒帶前綴的請求（本機、healthcheck）照常處理。UsePathBase 之後必須明確呼叫 UseRouting，
// 否則 Minimal API 會在最前面自動加上 routing，比對到的是還帶著前綴的路徑。
if (Environment.GetEnvironmentVariable("PATH_BASE") is { Length: > 0 } pathBase)
    app.UsePathBase(pathBase.TrimEnd('/'));
app.UseRouting();

app.MapGet("/health", async (ItemStore store) =>
{
    try
    {
        await store.PingAsync();
        return Results.Json(new { status = "ok", db = "ok", version });
    }
    catch (Exception ex)
    {
        return Results.Json(new { status = "error", db = ex.Message }, statusCode: 503);
    }
});

app.MapGet("/", () => Results.Json(new { name = "api-dotnet", version }));

app.MapGet("/items", async (ItemStore store) => Results.Json(await store.ListAsync()));

app.MapPost("/items", async (HttpRequest req, ItemStore store) =>
{
    var (input, error) = await ReadItemInputAsync(req);
    if (error is not null) return error;
    var item = await store.CreateAsync(input!);
    return Results.Created($"{req.PathBase}/items/{item.Id}", item);
});

app.MapGet("/items/{id}", async (string id, ItemStore store) =>
    ItemInput.ParseId(id) is int itemId && await store.GetAsync(itemId) is Item item
        ? Results.Json(item)
        : NotFound());

app.MapPut("/items/{id}", async (string id, HttpRequest req, ItemStore store) =>
{
    if (ItemInput.ParseId(id) is not int itemId) return NotFound();
    var (input, error) = await ReadItemInputAsync(req);
    if (error is not null) return error;
    return await store.UpdateAsync(itemId, input!) is Item item ? Results.Json(item) : NotFound();
});

app.MapDelete("/items/{id}", async (string id, ItemStore store) =>
    ItemInput.ParseId(id) is int itemId && await store.DeleteAsync(itemId)
        ? Results.NoContent()
        : NotFound());

app.MapFallback(() => Error(404, "not found"));

// DB 可能比 api 晚就緒（例如主機重開機），migration 失敗就重試，不讓進程直接結束
var startupStore = app.Services.GetRequiredService<ItemStore>();
for (var attempt = 1; ; attempt++)
{
    try
    {
        await startupStore.MigrateAsync();
        break;
    }
    catch (Exception ex)
    {
        app.Logger.LogError("migration failed (attempt {Attempt}): {Message}", attempt, ex.Message);
        await Task.Delay(TimeSpan.FromSeconds(Math.Min(attempt, 10)));
    }
}

app.Run();

static IResult Error(int status, string message) => Results.Json(new { error = message }, statusCode: status);

static IResult NotFound() => Error(404, "item not found");

static async Task<(ItemInput? Input, IResult? Error)> ReadItemInputAsync(HttpRequest req)
{
    if (!(req.ContentType ?? "").StartsWith("application/json", StringComparison.Ordinal))
        return (null, Error(415, "content-type must be application/json"));

    using var buffer = new MemoryStream();
    var chunk = new byte[8192];
    int read;
    while ((read = await req.Body.ReadAsync(chunk)) > 0)
    {
        if (buffer.Length + read > MaxBodyBytes) return (null, Error(413, "body too large"));
        buffer.Write(chunk, 0, read);
    }

    JsonElement body;
    try
    {
        using var doc = JsonDocument.Parse(buffer.ToArray());
        body = doc.RootElement.Clone();
    }
    catch (JsonException)
    {
        return (null, Error(400, "invalid JSON"));
    }

    var (input, error) = ItemInput.Parse(body);
    return error is null ? (input, null) : (null, Error(400, error));
}
