<?php

declare(strict_types=1);

namespace Api\Tests;

use Api\ItemInput;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\Attributes\TestWith;
use PHPUnit\Framework\TestCase;

/** 與 .NET 版的 ItemInputTests 相同的案例，確保三版的驗證規則一致。 */
final class ItemInputTest extends TestCase
{
    /** @return array{0: ?ItemInput, 1: ?string} */
    private static function parse(string $json): array
    {
        return ItemInput::parse(json_decode($json, false, 512, JSON_THROW_ON_ERROR));
    }

    public function test名稱會去除前後空白_done預設為false(): void
    {
        [$input, $error] = self::parse('{"name":"  買牛奶  "}');
        self::assertNull($error);
        self::assertEquals(new ItemInput('買牛奶', false), $input);
    }

    public function test全形空白也會去除(): void
    {
        [$input] = self::parse('{"name":"　買牛奶　"}');
        self::assertSame('買牛奶', $input?->name);
    }

    public function test可以指定done(): void
    {
        [$input] = self::parse('{"name":"x","done":true}');
        self::assertTrue($input?->done);
    }

    public function testDone為null視同未指定(): void
    {
        [$input, $error] = self::parse('{"name":"x","done":null}');
        self::assertNull($error);
        self::assertFalse($input?->done);
    }

    #[TestWith(['{}'])]
    #[TestWith(['{"name":""}'])]
    #[TestWith(['{"name":"   "}'])]
    #[TestWith(['{"name":123}'])]
    #[TestWith(['{"name":null}'])]
    #[TestWith(['[]'])]
    #[TestWith(['["x"]'])]
    #[TestWith(['null'])]
    #[TestWith(['"x"'])]
    public function test缺少名稱時回傳錯誤(string $json): void
    {
        self::assertSame([null, 'name is required'], self::parse($json));
    }

    public function test名稱最多200字(): void
    {
        self::assertNull(self::parse('{"name":"' . str_repeat('a', 200) . '"}')[1]);
        self::assertNull(self::parse('{"name":"' . str_repeat('中', 200) . '"}')[1]);
        self::assertSame(
            'name must be at most 200 characters',
            self::parse('{"name":"' . str_repeat('a', 201) . '"}')[1],
        );
    }

    public function test名稱長度與Node和NET一樣以UTF16計算(): void
    {
        // emoji 在 UTF-16 佔 2 個單位：100 個剛好 200，101 個超過
        self::assertNull(self::parse('{"name":"' . str_repeat('😀', 100) . '"}')[1]);
        self::assertSame(
            'name must be at most 200 characters',
            self::parse('{"name":"' . str_repeat('😀', 101) . '"}')[1],
        );
    }

    #[TestWith(['"yes"'])]
    #[TestWith(['1'])]
    #[TestWith(['0'])]
    #[TestWith(['{}'])]
    #[TestWith(['[]'])]
    public function testDone必須是布林(string $done): void
    {
        self::assertSame([null, 'done must be a boolean'], self::parse('{"name":"x","done":' . $done . '}'));
    }

    /** @return iterable<array{string, int}> */
    public static function validIds(): iterable
    {
        yield ['1', 1];
        yield ['42', 42];
        yield ['007', 7];
        yield ['2147483647', 2147483647];
    }

    #[DataProvider('validIds')]
    public function test合法的id(string $raw, int $expected): void
    {
        self::assertSame($expected, ItemInput::parseId($raw));
    }

    #[TestWith(['0'])]
    #[TestWith(['000'])]
    #[TestWith(['-1'])]
    #[TestWith(['abc'])]
    #[TestWith(['1.5'])]
    #[TestWith([' 1'])]
    #[TestWith(['1e2'])]
    #[TestWith(['2147483648'])]
    #[TestWith(['99999999999999999999'])]
    #[TestWith([''])]
    public function test不合法的id回傳null(string $raw): void
    {
        self::assertNull(ItemInput::parseId($raw));
    }
}
