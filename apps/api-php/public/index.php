<?php

// 與 Node 版（apps/api）、.NET 版（apps/api-dotnet）相同的 API：/health、/、/items CRUD；
// 欄位名稱、狀態碼、錯誤訊息一致，以便共用 scripts/smoke-test.sh 驗收。
// Caddyfile 把所有路徑都交給這支檔案，路由在下面處理。

declare(strict_types=1);

require __DIR__ . '/../src/ItemInput.php';
require __DIR__ . '/../src/ItemStore.php';

use Api\ItemInput;
use Api\ItemStore;

const MAX_BODY_BYTES = 64 * 1024;

final class HttpError extends Exception
{
    public function __construct(public readonly int $status, string $message)
    {
        parent::__construct($message);
    }
}

function send(int $status, mixed $body = null): void
{
    http_response_code($status);
    if ($status === 204) {
        return;
    }
    header('content-type: application/json');
    echo json_encode($body, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
}

function readJson(): mixed
{
    if (!str_starts_with($_SERVER['CONTENT_TYPE'] ?? '', 'application/json')) {
        throw new HttpError(415, 'content-type must be application/json');
    }
    // 先看 Content-Length；沒有的話（chunked）邊讀邊算，超過就停
    if ((int) ($_SERVER['CONTENT_LENGTH'] ?? 0) > MAX_BODY_BYTES) {
        throw new HttpError(413, 'body too large');
    }
    $raw = file_get_contents('php://input', false, null, 0, MAX_BODY_BYTES + 1);
    if (strlen((string) $raw) > MAX_BODY_BYTES) {
        throw new HttpError(413, 'body too large');
    }
    try {
        return json_decode((string) $raw, false, 512, JSON_THROW_ON_ERROR);
    } catch (JsonException) {
        throw new HttpError(400, 'invalid JSON');
    }
}

function parseItemInput(): ItemInput
{
    [$input, $error] = ItemInput::parse(readJson());
    if ($error !== null) {
        throw new HttpError(400, $error);
    }
    return $input;
}

function parseId(string $raw): int
{
    return ItemInput::parseId($raw) ?? throw new HttpError(404, 'item not found');
}

function handleItems(ItemStore $store, string $method, ?string $id, string $base): void
{
    if ($id === null) {
        if ($method === 'GET') {
            send(200, $store->list());
            return;
        }
        if ($method === 'POST') {
            $item = $store->create(parseItemInput());
            header("location: {$base}/items/{$item['id']}");
            send(201, $item);
            return;
        }
        throw new HttpError(405, 'method not allowed');
    }

    $itemId = parseId($id);
    if ($method === 'DELETE') {
        if (!$store->delete($itemId)) {
            throw new HttpError(404, 'item not found');
        }
        send(204);
        return;
    }
    $item = match ($method) {
        'GET' => $store->get($itemId),
        'PUT' => $store->update($itemId, parseItemInput()),
        default => throw new HttpError(405, 'method not allowed'),
    };
    if ($item === null) {
        throw new HttpError(404, 'item not found');
    }
    send(200, $item);
}

$version = getenv('APP_VERSION') ?: 'dev';
// 對外經 tunnel 時網址帶前綴（例如 /php），cloudflared 不會去掉，所以在這裡去掉；
// 沒帶前綴的請求（本機、healthcheck）照常處理。與 Node 版、ASP.NET Core 的 UsePathBase 行為相同。
$pathBase = rtrim(getenv('PATH_BASE') ?: '', '/');
$method = $_SERVER['REQUEST_METHOD'];
$fullPath = explode('?', $_SERVER['REQUEST_URI'] ?? '/', 2)[0];
[$base, $path] = $pathBase !== '' && ($fullPath === $pathBase || str_starts_with($fullPath, "{$pathBase}/"))
    ? [$pathBase, substr($fullPath, strlen($pathBase)) ?: '/']
    : ['', $fullPath];

// 請求紀錄：每個請求一行「方法 路徑 狀態碼 耗時」，例如 `POST /php/items 201 4ms`（格式與 Node、.NET 版相同）。
// 路徑不含 query string；成功的 /health 不記（docker healthcheck 每 10 秒打一次，會洗版）。
$start = hrtime(true);
register_shutdown_function(static function () use ($method, $fullPath, $path, $start): void {
    $status = http_response_code();
    if ($status === 200 && $path === '/health') {
        return;
    }
    $ms = (int) round((hrtime(true) - $start) / 1e6);
    file_put_contents('php://stdout', "{$method} {$fullPath} {$status} {$ms}ms\n");
});

$store = new ItemStore();
try {
    if ($method === 'GET' && $path === '/health') {
        try {
            $store->ping();
            send(200, ['status' => 'ok', 'db' => 'ok', 'version' => $version]);
        } catch (PDOException $e) {
            send(503, ['status' => 'error', 'db' => $e->getMessage()]);
        }
    } elseif ($method === 'GET' && $path === '/') {
        send(200, ['name' => 'api-php', 'version' => $version]);
    } elseif (preg_match('#^/items(?:/([^/]+))?/?$#', $path, $m) === 1) {
        handleItems($store, $method, $m[1] ?? null, $base);
    } else {
        throw new HttpError(404, 'not found');
    }
} catch (HttpError $e) {
    send($e->status, ['error' => $e->getMessage()]);
} catch (Throwable $e) {
    error_log((string) $e);
    send(500, ['error' => 'internal error']);
}
