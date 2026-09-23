using System.Text.Json;
using Api;

namespace Api.Tests;

public class ItemInputTests
{
    private static (ItemInput? Input, string? Error) Parse(string json) =>
        ItemInput.Parse(JsonDocument.Parse(json).RootElement);

    [Fact]
    public void 名稱會去除前後空白_done_預設為_false()
    {
        var (input, error) = Parse("""{"name":"  買牛奶  "}""");
        Assert.Null(error);
        Assert.Equal(new ItemInput("買牛奶", false), input);
    }

    [Fact]
    public void 可以指定_done()
    {
        var (input, _) = Parse("""{"name":"x","done":true}""");
        Assert.True(input!.Done);
    }

    [Fact]
    public void done_為_null_視同未指定()
    {
        var (input, error) = Parse("""{"name":"x","done":null}""");
        Assert.Null(error);
        Assert.False(input!.Done);
    }

    [Theory]
    [InlineData("""{}""")]
    [InlineData("""{"name":""}""")]
    [InlineData("""{"name":"   "}""")]
    [InlineData("""{"name":123}""")]
    [InlineData("""[]""")]
    [InlineData("""null""")]
    public void 缺少名稱時回傳錯誤(string json)
    {
        var (input, error) = Parse(json);
        Assert.Null(input);
        Assert.Equal("name is required", error);
    }

    [Fact]
    public void 名稱最多_200_字()
    {
        Assert.Null(Parse($$"""{"name":"{{new string('a', 200)}}"}""").Error);
        Assert.Equal("name must be at most 200 characters",
            Parse($$"""{"name":"{{new string('a', 201)}}"}""").Error);
    }

    [Theory]
    [InlineData("\"yes\"")]
    [InlineData("1")]
    [InlineData("{}")]
    public void done_必須是布林(string done)
    {
        var (input, error) = Parse($$"""{"name":"x","done":{{done}}}""");
        Assert.Null(input);
        Assert.Equal("done must be a boolean", error);
    }

    [Theory]
    [InlineData("1", 1)]
    [InlineData("42", 42)]
    [InlineData("2147483647", int.MaxValue)]
    public void 合法的_id(string raw, int expected) => Assert.Equal(expected, ItemInput.ParseId(raw));

    [Theory]
    [InlineData("0")]
    [InlineData("-1")]
    [InlineData("abc")]
    [InlineData("1.5")]
    [InlineData(" 1")]
    [InlineData("2147483648")]
    [InlineData("")]
    public void 不合法的_id_回傳_null(string raw) => Assert.Null(ItemInput.ParseId(raw));
}
