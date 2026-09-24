<?php

declare(strict_types=1);

namespace Api;

/** POST / PUT /items 的輸入；驗證規則與 Node 版（apps/api）、.NET 版（apps/api-dotnet）一致。 */
final class ItemInput
{
    public const MAX_NAME_LENGTH = 200;

    public function __construct(
        public readonly string $name,
        public readonly bool $done,
    ) {
    }

    /**
     * 驗證 json_decode 後的 body（物件為 stdClass）。
     * 成功回傳 [input, null]；失敗回傳 [null, 錯誤訊息]（對應 400）。
     *
     * @return array{0: ?ItemInput, 1: ?string}
     */
    public static function parse(mixed $body): array
    {
        $isObject = $body instanceof \stdClass;
        $name = $isObject && isset($body->name) && is_string($body->name) ? self::trim($body->name) : '';
        if ($name === '') {
            return [null, 'name is required'];
        }
        if (self::length($name) > self::MAX_NAME_LENGTH) {
            return [null, 'name must be at most ' . self::MAX_NAME_LENGTH . ' characters'];
        }

        $done = $body->done ?? false;
        if (!is_bool($done)) {
            return [null, 'done must be a boolean'];
        }
        return [new self($name, $done), null];
    }

    /** 解析路徑上的 id；不是正整數或超出 int4 範圍（2147483647）時回傳 null（對應 404）。 */
    public static function parseId(string $raw): ?int
    {
        if (preg_match('/^[0-9]+$/', $raw) !== 1) {
            return null;
        }
        $digits = ltrim($raw, '0');
        if ($digits === '' || strlen($digits) > 10) {
            return null;
        }
        $id = (int) $digits;
        return $id <= 2147483647 ? $id : null;
    }

    /** 去掉前後空白（含全形空白等 Unicode 空白），與 JavaScript 的 trim() 相近。 */
    private static function trim(string $value): string
    {
        return preg_replace('/^[\s\p{Z}\x{FEFF}]+|[\s\p{Z}\x{FEFF}]+$/u', '', $value) ?? $value;
    }

    /** 以 UTF-16 code unit 計算長度，與 Node（String.length）、.NET（string.Length）相同。 */
    private static function length(string $value): int
    {
        return intdiv(strlen(mb_convert_encoding($value, 'UTF-16LE', 'UTF-8')), 2);
    }
}
