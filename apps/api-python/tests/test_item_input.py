"""與 .NET 版 ItemInputTests、PHP 版 ItemInputTest 相同的案例，確保各版的驗證規則一致。"""

import json

import pytest

from app.item_input import ItemInput, parse_id, parse_item_input


def parse(text: str):
    return parse_item_input(json.loads(text))


def test_名稱會去除前後空白_done預設為false():
    assert parse('{"name":"  買牛奶  "}') == (ItemInput("買牛奶", False), None)


def test_全形空白也會去除():
    assert parse('{"name":"\\u3000買牛奶\\u3000"}')[0] == ItemInput("買牛奶", False)


def test_可以指定done():
    assert parse('{"name":"x","done":true}')[0] == ItemInput("x", True)


def test_done為null視同未指定():
    assert parse('{"name":"x","done":null}') == (ItemInput("x", False), None)


@pytest.mark.parametrize(
    "text", ["{}", '{"name":""}', '{"name":"   "}', '{"name":123}', '{"name":null}', "[]", '["x"]', "null", '"x"']
)
def test_缺少名稱時回傳錯誤(text):
    assert parse(text) == (None, "name is required")


def test_名稱最多200字():
    assert parse(json.dumps({"name": "a" * 200}))[1] is None
    assert parse(json.dumps({"name": "中" * 200}, ensure_ascii=False))[1] is None
    assert parse(json.dumps({"name": "a" * 201}))[1] == "name must be at most 200 characters"


def test_名稱長度與另外三版一樣以UTF16計算():
    # emoji 在 UTF-16 佔 2 個單位：100 個剛好 200，101 個超過
    assert parse(json.dumps({"name": "😀" * 100}))[1] is None
    assert parse(json.dumps({"name": "😀" * 101}))[1] == "name must be at most 200 characters"


@pytest.mark.parametrize("done", ['"yes"', "1", "0", "{}", "[]"])
def test_done必須是布林(done):
    assert parse('{"name":"x","done":' + done + "}") == (None, "done must be a boolean")


@pytest.mark.parametrize(("raw", "expected"), [("1", 1), ("42", 42), ("007", 7), ("2147483647", 2147483647)])
def test_合法的id(raw, expected):
    assert parse_id(raw) == expected


@pytest.mark.parametrize(
    "raw", ["0", "000", "-1", "abc", "1.5", " 1", "1e2", "１", "2147483648", "9" * 5000, ""]
)
def test_不合法的id回傳None(raw):
    assert parse_id(raw) is None
