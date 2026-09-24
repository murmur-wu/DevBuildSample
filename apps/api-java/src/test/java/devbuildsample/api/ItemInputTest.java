package devbuildsample.api;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.junit.jupiter.params.provider.ValueSource;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ObjectNode;

/** 與 .NET、PHP、Python、Go 版相同的案例，確保各版的驗證規則一致。 */
class ItemInputTest {

    private static final JsonMapper JSON = JsonMapper.builder().build();

    private static ItemInput.Parsed parse(String text) {
        return ItemInput.parse(JSON.readTree(text));
    }

    private static ItemInput.Parsed parseName(String name) {
        ObjectNode body = JSON.createObjectNode().put("name", name);
        return ItemInput.parse(body);
    }

    @Test
    void 名稱會去除前後空白且done預設為false() {
        assertEquals(new ItemInput("買牛奶", false), parse("{\"name\":\"  買牛奶  \"}").input());
    }

    @Test
    void 全形空白_不換行空白與BOM也會去除() {
        String bom = String.valueOf((char) 0xFEFF);
        String nbsp = String.valueOf((char) 0x00A0);
        String ideographic = String.valueOf((char) 0x3000);
        assertEquals("買牛奶", parseName(ideographic + bom + nbsp + "買牛奶" + nbsp + bom + ideographic).input().name());
    }

    @Test
    void done可以指定_null視同未指定() {
        assertEquals(true, parse("{\"name\":\"x\",\"done\":true}").input().done());
        ItemInput.Parsed parsed = parse("{\"name\":\"x\",\"done\":null}");
        assertNull(parsed.error());
        assertEquals(false, parsed.input().done());
    }

    @ParameterizedTest
    @ValueSource(strings = {"{}", "{\"name\":\"\"}", "{\"name\":\"   \"}", "{\"name\":123}", "{\"name\":null}", "[]", "[\"x\"]", "null", "\"x\""})
    void 缺少名稱時回傳錯誤(String text) {
        assertEquals("name is required", parse(text).error());
    }

    @Test
    void 名稱最多200字且以UTF16計算() {
        assertNull(parseName("a".repeat(200)).error());
        assertNull(parseName("中".repeat(200)).error());
        assertEquals("name must be at most 200 characters", parseName("a".repeat(201)).error());
        String emoji = new String(Character.toChars(0x1F600)); // UTF-16 佔 2 個單位
        assertNull(parseName(emoji.repeat(100)).error());
        assertEquals("name must be at most 200 characters", parseName(emoji.repeat(101)).error());
    }

    @ParameterizedTest
    @ValueSource(strings = {"\"yes\"", "1", "0", "{}", "[]"})
    void done必須是布林(String done) {
        assertEquals("done must be a boolean", parse("{\"name\":\"x\",\"done\":" + done + "}").error());
    }

    @ParameterizedTest
    @CsvSource({"1,1", "42,42", "007,7", "2147483647,2147483647"})
    void 合法的id(String raw, int expected) {
        assertEquals(expected, ItemInput.parseId(raw));
    }

    @ParameterizedTest
    @ValueSource(strings = {"0", "000", "-1", "abc", "1.5", " 1", "1e2", "2147483648", "99999999999999999999", ""})
    void 不合法的id回傳null(String raw) {
        assertNull(ItemInput.parseId(raw));
    }

    @Test
    void 全形數字與超長數字也不合法() {
        assertNull(ItemInput.parseId(String.valueOf((char) 0xFF11)));
        assertNull(ItemInput.parseId("9".repeat(5000)));
    }
}
