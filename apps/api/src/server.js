import http from 'node:http';
import pg from 'pg';

const port = Number(process.env.PORT ?? 3000);
const pool = new pg.Pool({
  host: process.env.DB_HOST ?? 'db',
  port: Number(process.env.DB_PORT ?? 5432),
  user: process.env.POSTGRES_USER ?? 'postgres',
  password: process.env.POSTGRES_PASSWORD,
  database: process.env.POSTGRES_DB ?? 'postgres',
  max: 5,
  connectionTimeoutMillis: 2000,
});

function send(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(body));
}

const server = http.createServer(async (req, res) => {
  if (req.method === 'GET' && req.url === '/health') {
    try {
      await pool.query('SELECT 1');
      return send(res, 200, { status: 'ok', db: 'ok', version: process.env.APP_VERSION ?? 'dev' });
    } catch (err) {
      return send(res, 503, { status: 'error', db: err.message });
    }
  }
  if (req.method === 'GET' && req.url === '/') {
    return send(res, 200, { name: 'api', version: process.env.APP_VERSION ?? 'dev' });
  }
  send(res, 404, { error: 'not found' });
});

server.listen(port, () => console.log(`api listening on :${port}`));

for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => {
    server.close(() => pool.end().finally(() => process.exit(0)));
  });
}
