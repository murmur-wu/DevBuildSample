package devbuildsample.api;

import java.util.regex.Pattern;
import tools.jackson.databind.JsonNode;

/** POST / PUT /items 的輸入；驗證規則與另外五版一致。 */
public record ItemInput(String name, boolean done) {

    public static final int MAX_NAME_LENGTH = 200;
    private static final Pattern ID = Pattern.compile("[0-9]+");

    /** 驗證結果：成功時 input 有值、error 為 null；失敗時相反（對應 400）。 */
    public record Parsed(ItemInput input, String error) {
        static Parsed ok(ItemInput input) { return new Parsed(input, null); }
        static Parsed fail(String error) { return new Parsed(null, error); }
    }

    public static Parsed parse(JsonNode body) {
        JsonNode rawName = body != null && body.isObject() ? body.get("name") : null;
        String name = rawName != null && rawName.isString() ? trim(rawName.stringValue()) : "";
        if (name.isEmpty()) {
            return Parsed.fail("name is required");
        }
        // Java 的 String.length() 本來就是 UTF-16 code unit，與 Node、.NET 相同；emoji 算 2
        if (name.length() > MAX_NAME_LENGTH) {
            return Parsed.fail("name must be at most " + MAX_NAME_LENGTH + " characters");
        }

        JsonNode done = body.get("done");
        if (done != null && !done.isNull() && !done.isBoolean()) {
            return Parsed.fail("done must be a boolean");
        }
        return Parsed.ok(new ItemInput(name, done != null && done.isBoolean() && done.booleanValue()));
    }

    /** 解析路徑上的 id；不是正整數或超出 int4 範圍（2147483647）時回傳 null（對應 404）。 */
    public static Integer parseId(String raw) {
        if (raw == null || !ID.matcher(raw).matches()) {
            return null;
        }
        String digits = raw.replaceFirst("^0+", "");
        if (digits.isEmpty() || digits.length() > 10) {
            return null;
        }
        long id = Long.parseLong(digits);
        return id <= Integer.MAX_VALUE ? (int) id : null;
    }

    /** 去掉前後空白：Unicode 空白（含全形空白）再加上 BOM（U+FEFF），與 JavaScript 的 trim() 相近。 */
    static String trim(String value) {
        int start = 0;
        int end = value.length();
        while (start < end && isTrimmable(value.charAt(start))) {
            start++;
        }
        while (end > start && isTrimmable(value.charAt(end - 1))) {
            end--;
        }
        return value.substring(start, end);
    }

    private static boolean isTrimmable(char c) {
        // isWhitespace 不含不換行空白（U+00A0 等），所以另外用 isSpaceChar 補上
        return Character.isWhitespace(c) || Character.isSpaceChar(c) || c == 0xFEFF;
    }
}
