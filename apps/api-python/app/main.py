"""與 Node、.NET、PHP 版相同的 API：/health、/、/items CRUD；欄位名稱、狀態碼、錯誤訊息一致，
以便共用 scripts/smoke-test.sh 驗收。

不使用 FastAPI 的自動驗證（錯誤會回 422 與不同的格式），改為與另外三版一樣自己讀 JSON、自己檢查；
FastAPI 內建的 /docs 也關閉，API 文件統一由前端的 Swagger UI（openapi.yaml）提供。
"""

import json
import os
import time
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response
from starlette.exceptions import HTTPException as StarletteHTTPException

from .item_input import ItemInput, parse_id, parse_item_input
from .store import ItemStore

MAX_BODY_BYTES = 64 * 1024
VERSION = os.environ.get("APP_VERSION", "dev")
# 對外經 tunnel 時網址帶前綴（例如 /py），cloudflared 不會去掉，所以在 app() 裡處理；
# 沒帶前綴的請求（本機、healthcheck）照常處理。與 Node 版、ASP.NET Core 的 UsePathBase 行為相同。
PATH_BASE = os.environ.get("PATH_BASE", "").rstrip("/")


class HttpError(Exception):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.message = message


def error(status: int, message: str) -> JSONResponse:
    return JSONResponse({"error": message}, status_code=status)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # 資料表已由 app/entrypoint.py 在啟動 uvicorn 前建立
    store = ItemStore()
    await store.open()
    app.state.store = store
    yield
    await store.close()


api = FastAPI(docs_url=None, redoc_url=None, openapi_url=None, redirect_slashes=False, lifespan=lifespan)


def store_of(request: Request) -> ItemStore:
    return request.app.state.store


@api.exception_handler(HttpError)
async def handle_http_error(request: Request, exc: HttpError) -> JSONResponse:
    return error(exc.status, exc.message)


@api.exception_handler(StarletteHTTPException)
async def handle_starlette_error(request: Request, exc: StarletteHTTPException) -> JSONResponse:
    # 路由比對失敗時的 404 / 405，改成與另外三版相同的訊息；
    # 與 Node 版一樣，只有 /items 相關路徑回 405，其他路徑（例如 POST /health）一律 404
    route_path = request.scope["path"][len(request.scope.get("root_path", "")):] or "/"
    if exc.status_code == 405 and (route_path == "/items" or route_path.startswith("/items/")):
        return error(405, "method not allowed")
    if exc.status_code in (404, 405):
        return error(404, "not found")
    return error(exc.status_code, str(exc.detail))


@api.exception_handler(Exception)
async def handle_unexpected(request: Request, exc: Exception) -> JSONResponse:
    return error(500, "internal error")


async def read_json(request: Request) -> Any:
    if not request.headers.get("content-type", "").startswith("application/json"):
        raise HttpError(415, "content-type must be application/json")
    # 先看 Content-Length；沒有的話（chunked）邊讀邊算，超過就停
    length = request.headers.get("content-length", "")
    if length.isascii() and length.isdigit() and int(length) > MAX_BODY_BYTES:
        raise HttpError(413, "body too large")
    body = bytearray()
    async for chunk in request.stream():
        body += chunk
        if len(body) > MAX_BODY_BYTES:
            raise HttpError(413, "body too large")
    try:
        return json.loads(body)
    except (ValueError, RecursionError):
        raise HttpError(400, "invalid JSON") from None


async def read_item_input(request: Request) -> ItemInput:
    item, message = parse_item_input(await read_json(request))
    if item is None:
        raise HttpError(400, message or "invalid input")
    return item


def require_id(raw: str) -> int:
    item_id = parse_id(raw)
    if item_id is None:
        raise HttpError(404, "item not found")
    return item_id


@api.get("/health")
async def health(request: Request) -> JSONResponse:
    try:
        await store_of(request).ping()
    except Exception as exc:
        return JSONResponse({"status": "error", "db": str(exc)}, status_code=503)
    return JSONResponse({"status": "ok", "db": "ok", "version": VERSION})


@api.get("/")
async def info() -> JSONResponse:
    return JSONResponse({"name": "api-python", "version": VERSION})


# 與 Node 版一樣接受結尾的 /（例如 /items/、/items/1/）
@api.get("/items")
@api.get("/items/")
async def list_items(request: Request) -> JSONResponse:
    return JSONResponse(await store_of(request).list())


@api.post("/items")
@api.post("/items/")
async def create_item(request: Request) -> JSONResponse:
    item_input = await read_item_input(request)
    item = await store_of(request).create(item_input)
    location = f"{request.scope.get('root_path', '')}/items/{item['id']}"
    return JSONResponse(item, status_code=201, headers={"location": location})


@api.get("/items/{raw_id}")
@api.get("/items/{raw_id}/")
async def get_item(raw_id: str, request: Request) -> JSONResponse:
    item_id = require_id(raw_id)
    item = await store_of(request).get(item_id)
    if item is None:
        raise HttpError(404, "item not found")
    return JSONResponse(item)


@api.put("/items/{raw_id}")
@api.put("/items/{raw_id}/")
async def update_item(raw_id: str, request: Request) -> JSONResponse:
    item_id = require_id(raw_id)
    item_input = await read_item_input(request)
    item = await store_of(request).update(item_id, item_input)
    if item is None:
        raise HttpError(404, "item not found")
    return JSONResponse(item)


@api.delete("/items/{raw_id}")
@api.delete("/items/{raw_id}/")
async def delete_item(raw_id: str, request: Request) -> Response:
    item_id = require_id(raw_id)
    if not await store_of(request).delete(item_id):
        raise HttpError(404, "item not found")
    return Response(status_code=204)


async def app(scope: dict[str, Any], receive: Any, send: Any) -> None:
    """最外層的 ASGI app：處理路徑前綴，並輸出請求紀錄（uvicorn 啟動時指定這個 app）。"""
    if scope["type"] != "http":
        await api(scope, receive, send)
        return

    # 紀錄用原始路徑（未解碼、不含 query string），與 Node 版相同
    raw_path = scope.get("raw_path")
    full_path = raw_path.decode("latin-1") if raw_path else scope["path"]
    route_path = scope["path"]
    path = scope["path"]
    if PATH_BASE and (path == PATH_BASE or path.startswith(PATH_BASE + "/")):
        route_path = path[len(PATH_BASE):] or "/"
        # ASGI 規定 path 要包含 root_path；Starlette 比對路由時會自己去掉 root_path
        scope = {**scope, "root_path": PATH_BASE, "path": PATH_BASE + route_path}

    # 請求紀錄：每個請求一行「方法 路徑 狀態碼 耗時」，例如 `POST /py/items 201 4ms`（格式與另外三版相同）。
    # 成功的 /health 不記（docker healthcheck 每 10 秒打一次，會洗版）。
    start = time.perf_counter()
    status = 500

    async def send_with_status(message: dict[str, Any]) -> None:
        nonlocal status
        if message["type"] == "http.response.start":
            status = message["status"]
        await send(message)

    try:
        await api(scope, receive, send_with_status)
    finally:
        if not (status == 200 and route_path == "/health"):
            ms = round((time.perf_counter() - start) * 1000)
            print(f"{scope['method']} {full_path} {status} {ms}ms", flush=True)
