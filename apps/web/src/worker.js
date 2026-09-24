// API 代轉：瀏覽器只呼叫同網域的 /api/<backend>/...，由 Worker 轉給後端，
// 因此不會有跨網域（CORS）問題，後端也不用改。其他路徑由 wrangler.jsonc 的 assets 直接回靜態檔案。
//   /api/node/items    → NODE_API/items    （例如 https://api-staging.heitang.info/node/items）
//   /api/dotnet/items  → DOTNET_API/items
//   /api/php/items     → PHP_API/items
const BACKENDS = { node: 'NODE_API', dotnet: 'DOTNET_API', php: 'PHP_API' };

function json(status, body) {
  return Response.json(body, { status });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const match = url.pathname.match(/^\/api\/([^/]+)(\/.*)?$/);
    const name = match?.[1];
    const base = Object.hasOwn(BACKENDS, name ?? '') ? env[BACKENDS[name]] : undefined;
    if (!base) return json(404, { error: 'unknown backend' });

    const baseUrl = new URL(base);
    const basePath = baseUrl.pathname.replace(/\/+$/, '');
    const target = new URL(`${basePath}${match[2] ?? '/'}${url.search}`, baseUrl);

    let upstream;
    try {
      // 沿用原請求的 method、headers、body；redirect 交給瀏覽器處理
      upstream = await fetch(new Request(target, request), { redirect: 'manual' });
    } catch (err) {
      console.error(`proxy to ${target} failed: ${err}`);
      return json(502, { error: 'backend unreachable' });
    }

    // 後端回的 Location 是它自己的路徑（例如 /node/items/1），改寫成前端看得到的 /api/node/items/1
    const response = new Response(upstream.body, upstream);
    const location = response.headers.get('location');
    if (location?.startsWith(`${basePath}/`)) {
      response.headers.set('location', `/api/${name}${location.slice(basePath.length)}`);
    }
    return response;
  },
};
