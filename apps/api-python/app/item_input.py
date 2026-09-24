"""POST / PUT /items 的輸入驗證；規則與 Node、.NET、PHP 版一致。"""

import re
from dataclasses import dataclass
from typing import Any

MAX_NAME_LENGTH = 200

# 前後空白：Unicode 空白（含全形空白）再加上 BOM（U+FEFF），與 JavaScript 的 trim() 相近
_TRIM = re.compile(r"^[\s\ufeff]+|[\s\ufeff]+$")
_ID = re.compile(r"[0-9]+")  # 只接受 ASCII 數字（str.isdigit() 會接受全形數字等）


@dataclass(frozen=True)
class ItemInput:
    name: str
    done: bool


def parse_item_input(body: Any) -> tuple[ItemInput | None, str | None]:
    """驗證 json.loads 後的 body。成功回傳 (input, None)；失敗回傳 (None, 錯誤訊息)（對應 400）。"""
    raw_name = body.get("name") if isinstance(body, dict) else None
    name = _TRIM.sub("", raw_name) if isinstance(raw_name, str) else ""
    if not name:
        return None, "name is required"
    if _utf16_length(name) > MAX_NAME_LENGTH:
        return None, f"name must be at most {MAX_NAME_LENGTH} characters"

    done = body.get("done")
    if done is None:
        done = False
    if not isinstance(done, bool):
        return None, "done must be a boolean"
    return ItemInput(name, done), None


def parse_id(raw: str) -> int | None:
    """解析路徑上的 id；不是正整數或超出 int4 範圍（2147483647）時回傳 None（對應 404）。"""
    # 先擋掉過長的數字：int() 遇到超過 4300 位數的字串會丟例外
    if not _ID.fullmatch(raw) or len(raw.lstrip("0")) > 10:
        return None
    item_id = int(raw)
    return item_id if 0 < item_id <= 2147483647 else None


def _utf16_length(value: str) -> int:
    """以 UTF-16 code unit 計算長度，與 Node（String.length）、.NET（string.Length）相同；emoji 算 2。"""
    return len(value.encode("utf-16-le", "surrogatepass")) // 2
