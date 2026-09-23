using System.Text.Json;

namespace Api;

/// <summary>POST / PUT /items 的輸入；驗證規則與 Node 版（apps/api）一致。</summary>
public sealed record ItemInput(string Name, bool Done)
{
    public const int MaxNameLength = 200;

    /// <summary>驗證 JSON body。成功回傳 input、error 為 null；失敗回傳 null 與錯誤訊息（對應 400）。</summary>
    public static (ItemInput? Input, string? Error) Parse(JsonElement body)
    {
        var name = body.ValueKind == JsonValueKind.Object
            && body.TryGetProperty("name", out var n)
            && n.ValueKind == JsonValueKind.String
                ? n.GetString()!.Trim()
                : "";
        if (name.Length == 0) return (null, "name is required");
        if (name.Length > MaxNameLength) return (null, $"name must be at most {MaxNameLength} characters");

        var done = false;
        if (body.TryGetProperty("done", out var d) && d.ValueKind != JsonValueKind.Null)
        {
            if (d.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
                return (null, "done must be a boolean");
            done = d.GetBoolean();
        }
        return (new ItemInput(name, done), null);
    }

    /// <summary>解析路徑上的 id；不是正整數或超出 int 範圍時回傳 null（對應 404）。</summary>
    public static int? ParseId(string raw) =>
        int.TryParse(raw, System.Globalization.NumberStyles.None, null, out var id) && id > 0 ? id : null;
}
