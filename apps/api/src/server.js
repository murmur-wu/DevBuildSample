import http from 'node:http';
import pg from 'pg';

const port = Number(process.env.PORT ?? 3000);
const version = process.env.APP_VERSION ?? 'dev';
const MAX_BODY_BYTES = 64 * 1024;
const MAX_NAME_LENGTH = 200;

const pool = new pg.Pool({
  host: process.env.DB_HOST ?? 'db',
  port: Number(process.env.DB_PORT ?? 5432),
  user: process.env.POSTGRES_USER ?? 'postgres',
  password: process.env.POSTGRES_PASSWORD,
  database: process.env.POSTGRES_DB ?? 'postgres',
  max: 5,
  connectionTimeoutMillis: 2000,
});

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

function send(res, status, body) {
  if (status === 204) {
    res.writeHead(204);
    return res.end();
  }
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(body));
}

async function readJson(req) {
  if (!(req.headers['content-type'] ?? '').startsWith('application/json')) {
    throw new HttpError(415, 'content-type must be application/json');
  }
  let size = 0;
  const chunks = [];
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) throw new HttpError(413, 'body too large');
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    throw new HttpError(400, 'invalid JSON');
  }
}

function parseItemInput(body) {
  const name = typeof body?.name === 'string' ? body.name.trim() : '';
  if (!name) throw new HttpError(400, 'name is required');
  if (name.length > MAX_NAME_LENGTH) throw new HttpError(400, `name must be at most ${MAX_NAME_LENGTH} characters`);
  const done = body.done ?? false;
  if (typeof done !== 'boolean') throw new HttpError(400, 'done must be a boolean');
  return { name, done };
}

function parseId(raw) {
  const id = Number(raw);
  if (!Number.isSafeInteger(id) || id <= 0 || id > 2147483647) throw new HttpError(404, 'item not found');
  return id;
}

async function migrate() {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS items (
      id         serial PRIMARY KEY,
      name       text NOT NULL,
      done       boolean NOT NULL DEFAULT false,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
  `);
}

const ITEM_COLUMNS = 'id, name, done, created_at, updated_at';

async function handleItems(req, res, id) {
  if (id === undefined) {
    if (req.method === 'GET') {
      const { rows } = await pool.query(`SELECT ${ITEM_COLUMNS} FROM items ORDER BY id`);
      return send(res, 200, rows);
    }
    if (req.method === 'POST') {
      const { name, done } = parseItemInput(await readJson(req));
      const { rows } = await pool.query(
        `INSERT INTO items (name, done) VALUES ($1, $2) RETURNING ${ITEM_COLUMNS}`,
        [name, done],
      );
      res.setHeader('location', `/items/${rows[0].id}`);
      return send(res, 201, rows[0]);
    }
    throw new HttpError(405, 'method not allowed');
  }

  const itemId = parseId(id);
  let result;
  if (req.method === 'GET') {
    result = await pool.query(`SELECT ${ITEM_COLUMNS} FROM items WHERE id = $1`, [itemId]);
  } else if (req.method === 'PUT') {
    const { name, done } = parseItemInput(await readJson(req));
    result = await pool.query(
      `UPDATE items SET name = $2, done = $3, updated_at = now() WHERE id = $1 RETURNING ${ITEM_COLUMNS}`,
      [itemId, name, done],
    );
  } else if (req.method === 'DELETE') {
    result = await pool.query('DELETE FROM items WHERE id = $1', [itemId]);
    if (result.rowCount === 0) throw new HttpError(404, 'item not found');
    return send(res, 204);
  } else {
    throw new HttpError(405, 'method not allowed');
  }
  if (result.rowCount === 0) throw new HttpError(404, 'item not found');
  return send(res, 200, result.rows[0]);
}

const server = http.createServer(async (req, res) => {
  const { pathname } = new URL(req.url, 'http://localhost');
  try {
    if (req.method === 'GET' && pathname === '/health') {
      try {
        await pool.query('SELECT 1');
        return send(res, 200, { status: 'ok', db: 'ok', version });
      } catch (err) {
        return send(res, 503, { status: 'error', db: err.message });
      }
    }
    if (req.method === 'GET' && pathname === '/') {
      return send(res, 200, { name: 'api', version });
    }
    const match = pathname.match(/^\/items(?:\/([^/]+))?\/?$/);
    if (match) return await handleItems(req, res, match[1]);
    throw new HttpError(404, 'not found');
  } catch (err) {
    if (err instanceof HttpError) return send(res, err.status, { error: err.message });
    console.error(err);
    return send(res, 500, { error: 'internal error' });
  }
});

// DB 可能比 api 晚就緒（例如 VM 重開機），migration 失敗就重試，不讓進程直接掛掉
async function start() {
  for (let attempt = 1; ; attempt++) {
    try {
      await migrate();
      break;
    } catch (err) {
      console.error(`migration failed (attempt ${attempt}): ${err.message}`);
      await new Promise((r) => setTimeout(r, Math.min(attempt, 10) * 1000));
    }
  }
  server.listen(port, () => console.log(`api listening on :${port}`));
}

start();

for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => {
    // 尚未 listen 時 close 也會立刻回呼（帶 ERR_SERVER_NOT_RUNNING），一樣能正常退出
    server.close(() => pool.end().finally(() => process.exit(0)));
  });
}
