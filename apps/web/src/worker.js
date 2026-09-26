// API 代轉：瀏覽器只呼叫同網域的 /api/<backend>/...，由 Worker 轉給後端，
// 因此不會有跨網域（CORS）問題，後端也不用改。其他路徑由 wrangler.jsonc 的 assets 直接回靜態檔案。
//   /api/node/items    → NODE_API/items    （例如 https://api-staging.heitang.info/node/items）
//   /api/dotnet/items  → DOTNET_API/items
//   /api/php/items     → PHP_API/items
//   /api/py/items      → PY_API/items
//   /api/go/items      → GO_API/items
//   /api/java/items    → JAVA_API/items
const BACKENDS = {
  node: 'NODE_API',
  dotnet: 'DOTNET_API',
  php: 'PHP_API',
  py: 'PY_API',
  go: 'GO_API',
  java: 'JAVA_API',
};

function json(status, body) {
  return Response.json(body, { status });
}

// 後端（api-staging）受 Cloudflare Access 保護，只接受帶 service token 的請求；
// token 存在 Worker 的 secrets（CF_ACCESS_CLIENT_ID、CF_ACCESS_CLIENT_SECRET，設定在 Cloudflare dashboard，不進 git）。
// 本機開發（.dev.vars 沒設）時不帶，直接打本機後端。
function withAccessToken(request, env) {
  if (env.CF_ACCESS_CLIENT_ID && env.CF_ACCESS_CLIENT_SECRET) {
    request.headers.set('CF-Access-Client-Id', env.CF_ACCESS_CLIENT_ID);
    request.headers.set('CF-Access-Client-Secret', env.CF_ACCESS_CLIENT_SECRET);
  }
  return request;
}

// 被 Access 擋下時會轉址到 <team>.cloudflareaccess.com 的登入頁，或回 401/403（各版後端本身不會回這兩個狀態碼）。
// 不要把轉址交給瀏覽器（跨網域會變成看不懂的 CORS 錯誤），改回明確的 502
function isAccessDenied(response) {
  const location = response.headers.get('location') ?? '';
  return (response.status >= 300 && response.status < 400 && /\.cloudflareaccess\.com\//.test(location))
    || response.status === 401 || response.status === 403;
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
      upstream = await fetch(withAccessToken(new Request(target, request), env), { redirect: 'manual' });
    } catch (err) {
      console.error(`proxy to ${target} failed: ${err}`);
      return json(502, { error: 'backend unreachable' });
    }
    if (isAccessDenied(upstream)) {
      // 狀態碼放最前面（dashboard 的 log 列表會截斷長訊息）；只記錄 token 是否設定與長度，不記錄值
      const id = env.CF_ACCESS_CLIENT_ID ?? '';
      const secret = env.CF_ACCESS_CLIENT_SECRET ?? '';
      console.error(`Access denied ${upstream.status}: id=${id ? `set(len ${id.length}, ends ${id.slice(-10)})` : 'missing'} secret=${secret ? `set(len ${secret.length})` : 'missing'} target=${target}`);
      return json(502, { error: 'backend access denied' });
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
