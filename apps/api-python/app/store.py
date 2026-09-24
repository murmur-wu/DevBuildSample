"""items 資料表的存取；資料表與查詢條件與另外三版相同。

時間戳在 SQL 裡轉成 UTC 的 ISO 8601（微秒，與 .NET、PHP 版相同精度），不受連線時區影響。
"""

import os
from typing import Any

import psycopg
from psycopg.rows import dict_row
from psycopg_pool import AsyncConnectionPool

from .item_input import ItemInput

_COLUMNS = """
    id, name, done,
    to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS created_at,
    to_char(updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS updated_at
"""

SCHEMA = """
    CREATE TABLE IF NOT EXISTS items (
      id         serial PRIMARY KEY,
      name       text NOT NULL,
      done       boolean NOT NULL DEFAULT false,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
"""

Item = dict[str, Any]


def connect_kwargs() -> dict[str, Any]:
    return {
        "host": os.environ.get("DB_HOST", "db"),
        "port": int(os.environ.get("DB_PORT", "5432")),
        "user": os.environ.get("POSTGRES_USER", "postgres"),
        "password": os.environ.get("POSTGRES_PASSWORD"),
        "dbname": os.environ.get("POSTGRES_DB", "postgres"),
        "connect_timeout": 2,
        "autocommit": True,
    }


def migrate() -> None:
    """建立資料表；容器啟動時由 app/entrypoint.py 呼叫（啟動 uvicorn 之前）。"""
    with psycopg.connect(**connect_kwargs()) as conn:
        conn.execute(SCHEMA)


class ItemStore:
    def __init__(self) -> None:
        self._pool = AsyncConnectionPool(
            kwargs={**connect_kwargs(), "row_factory": dict_row},
            min_size=1,
            max_size=5,
            timeout=2,  # 取得連線最多等 2 秒（DB 連不上時 /health 會回 503，不會卡住）
            # 借出前先確認連線還活著：DB 重啟後，池裡的舊連線會失效
            check=AsyncConnectionPool.check_connection,
            open=False,
        )

    async def open(self) -> None:
        # wait=False：DB 還沒就緒也先開，連線由 pool 在背景重試
        await self._pool.open(wait=False)

    async def close(self) -> None:
        await self._pool.close()

    async def ping(self) -> None:
        async with self._pool.connection() as conn:
            await conn.execute("SELECT 1")

    async def list(self) -> list[Item]:
        return await self._fetch_all(f"SELECT {_COLUMNS} FROM items ORDER BY id")

    async def get(self, item_id: int) -> Item | None:
        rows = await self._fetch_all(f"SELECT {_COLUMNS} FROM items WHERE id = %s", (item_id,))
        return rows[0] if rows else None

    async def create(self, item: ItemInput) -> Item:
        rows = await self._fetch_all(
            f"INSERT INTO items (name, done) VALUES (%s, %s) RETURNING {_COLUMNS}",
            (item.name, item.done),
        )
        return rows[0]

    async def update(self, item_id: int, item: ItemInput) -> Item | None:
        rows = await self._fetch_all(
            f"UPDATE items SET name = %s, done = %s, updated_at = now() WHERE id = %s RETURNING {_COLUMNS}",
            (item.name, item.done, item_id),
        )
        return rows[0] if rows else None

    async def delete(self, item_id: int) -> bool:
        async with self._pool.connection() as conn:
            cur = await conn.execute("DELETE FROM items WHERE id = %s", (item_id,))
            return cur.rowcount > 0

    async def _fetch_all(self, sql: str, params: tuple[Any, ...] = ()) -> list[Item]:
        async with self._pool.connection() as conn:
            cur = await conn.execute(sql, params)
            return await cur.fetchall()
