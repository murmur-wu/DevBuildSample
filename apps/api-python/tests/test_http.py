"""不需要資料庫的 HTTP 行為：路徑前綴、錯誤訊息與狀態碼（與另外三版一致）。
需要資料庫的部分（CRUD）由 scripts/smoke-test.sh 驗收。"""

import pytest
from fastapi.testclient import TestClient

from app import main


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(main, "PATH_BASE", "/py")
    # 不用 with：不執行 lifespan，所以不會連資料庫
    return TestClient(main.app)


@pytest.mark.parametrize("prefix", ["", "/py"])
def test_根路徑回傳名稱與版本(client, prefix):
    res = client.get(f"{prefix}/")
    assert res.status_code == 200
    assert res.json() == {"name": "api-python", "version": main.VERSION}


def test_只有前綴也視為根路徑(client):
    assert client.get("/py").json()["name"] == "api-python"


@pytest.mark.parametrize("path", ["/nope", "/py/nope", "/pyx/", "/pyx/items"])
def test_未知路徑回404(client, path):
    res = client.get(path)
    assert (res.status_code, res.json()) == (404, {"error": "not found"})


@pytest.mark.parametrize(("method", "path"), [("POST", "/health"), ("DELETE", "/"), ("PUT", "/py/health")])
def test_items以外的路徑用錯method也回404(client, method, path):
    res = client.request(method, path)
    assert (res.status_code, res.json()) == (404, {"error": "not found"})


@pytest.mark.parametrize("path", ["/items", "/py/items", "/items/1"])
def test_items用錯method回405(client, path):
    res = client.patch(path)
    assert (res.status_code, res.json()) == (405, {"error": "method not allowed"})


@pytest.mark.parametrize("raw_id", ["abc", "0", "-1", "2147483648"])
def test_不合法的id回404(client, raw_id):
    res = client.get(f"/py/items/{raw_id}")
    assert (res.status_code, res.json()) == (404, {"error": "item not found"})


def test_不合法的id優先於body檢查(client):
    res = client.put("/items/abc", content="x", headers={"content-type": "text/plain"})
    assert (res.status_code, res.json()) == (404, {"error": "item not found"})


def test_content_type不是json回415(client):
    res = client.post("/items", content='{"name":"x"}', headers={"content-type": "text/plain"})
    assert (res.status_code, res.json()) == (415, {"error": "content-type must be application/json"})


def test_body超過64KB回413(client):
    res = client.post("/items", content="x" * (64 * 1024 + 1), headers={"content-type": "application/json"})
    assert (res.status_code, res.json()) == (413, {"error": "body too large"})


def test_chunked的body超過64KB也回413(client):
    def chunks():
        for _ in range(20):
            yield b"x" * 8192

    res = client.post("/items", content=chunks(), headers={"content-type": "application/json"})
    assert (res.status_code, res.json()) == (413, {"error": "body too large"})


@pytest.mark.parametrize(
    ("body", "message"),
    [
        ("{not json", "invalid JSON"),
        ("", "invalid JSON"),
        ("[" * 50000, "invalid JSON"),  # 巢狀太深（Python 的遞迴上限）也視為不合法
        ('{"name":""}', "name is required"),
        ('{"name":"x","done":"yes"}', "done must be a boolean"),
    ],
    ids=["invalid", "empty", "too-deep", "empty-name", "done-not-bool"],
)
def test_輸入錯誤回400(client, body, message):
    res = client.post("/py/items", content=body, headers={"content-type": "application/json; charset=utf-8"})
    assert (res.status_code, res.json()) == (400, {"error": message})


def test_請求紀錄格式(client, capsys):
    client.get("/py/items/abc?x=1")
    client.get("/py/nope")
    lines = capsys.readouterr().out.splitlines()
    assert lines[0].startswith("GET /py/items/abc 404 ") and lines[0].endswith("ms")
    assert lines[1].startswith("GET /py/nope 404 ")
