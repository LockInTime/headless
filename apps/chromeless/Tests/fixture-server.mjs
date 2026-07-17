import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), 'Fixtures');
const routes = new Map([
  ['/designers/dashboard', 'dashboard.html'],
  ['/next', 'next.html'],
  ['/hostile', 'hostile.html'],
]);

const server = createServer(async (request, response) => {
  const pathname = new URL(request.url ?? '/', 'http://127.0.0.1').pathname;
  if (pathname === '/api/diagnostic') {
    const body = Buffer.from(JSON.stringify({ok: true}));
    response.writeHead(200, {
      'content-type': 'application/json; charset=utf-8',
      'content-length': body.length,
      'x-visible-response': 'fixture',
      'x-api-key': 'response-secret',
      'cache-control': 'no-store',
    });
    response.end(body);
    return;
  }
  const fixture = routes.get(pathname);
  if (!fixture) {
    response.writeHead(404, {'content-type': 'text/plain; charset=utf-8'});
    response.end('Not found');
    return;
  }
  const body = await readFile(join(root, fixture));
  const contentType = 'text/html; charset=utf-8';
  response.writeHead(200, {
    'content-type': contentType,
    'content-length': body.length,
    'cache-control': 'no-store',
    ...(pathname === '/designers/dashboard' ? {'set-cookie': 'qa_session=fixture-cookie; Path=/; SameSite=Lax'} : {}),
  });
  response.end(body);
});

const port = Number.parseInt(process.env.CHROMELESS_FIXTURE_PORT ?? '41739', 10);
if (!Number.isInteger(port) || port < 1024 || port > 65535) {
  throw new Error('CHROMELESS_FIXTURE_PORT must be an unprivileged TCP port');
}

server.listen(port, '127.0.0.1', () => {
  console.log(`fixture server ready at http://127.0.0.1:${port}`);
});
