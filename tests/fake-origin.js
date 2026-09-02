#!/usr/bin/env node
/**
 * A real HTTP origin for tests/run.sh.
 *
 * It serves the ACTUAL committed archives under data/, so the bytes a test
 * downloads are the same bytes sources.json is pinned to. Nothing in the test
 * computes a hash: the pins come from the checked-in sources.json and the bytes
 * come from the checked-in data/. That is what keeps the suite from supplying
 * the thing it asserts.
 *
 * Routes -- the failure modes are the ones reproduced by execution against the
 * old workflow, not invented ones:
 *
 *   /good/<name>      the real file, complete and correct
 *   /notfound/<name>  a clean HTTP 404
 *   /truncate/<name>  HTTP 200 declaring the full Content-Length, then the
 *                     connection is dropped after TRUNCATE_AT bytes. This is
 *                     the case that destroyed a good file: curl exits 18
 *                     having already written a partial body.
 *   /soft404/<name>   HTTP 200 carrying an HTML error page. A successful HTTP
 *                     status is not a valid body.
 *   /badhash/<name>   the real file with its LAST BYTE FLIPPED. Same length,
 *                     different sha256 -- so a size check cannot catch it and
 *                     the hash comparison is the only thing that can.
 */
const http = require('http');
const fs = require('fs');
const path = require('path');

const DATA_DIR = process.env.FAKE_ORIGIN_DATA || path.join(__dirname, '..', 'data');
const TRUNCATE_AT = 100;

const read = (name) => fs.readFileSync(path.join(DATA_DIR, name));

const server = http.createServer((req, res) => {
  const m = /^\/([a-z0-9]+)\/(.+)$/.exec(req.url);
  if (!m) { res.writeHead(400); return res.end('bad test route'); }
  const [, mode, name] = m;

  let real;
  try { real = read(name); }
  catch { res.writeHead(500); return res.end('fixture missing: ' + name); }

  switch (mode) {
    case 'good':
      res.writeHead(200, { 'Content-Type': 'application/zip', 'Content-Length': String(real.length) });
      return res.end(real);

    case 'notfound':
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      return res.end('Not Found');

    case 'truncate':
      // Declare the full length, deliver part of it, then vanish.
      res.writeHead(200, { 'Content-Type': 'application/zip', 'Content-Length': String(real.length) });
      res.write(real.subarray(0, TRUNCATE_AT));
      return setTimeout(() => res.socket && res.socket.destroy(), 20);

    case 'soft404': {
      const body = '<html><body>Page not found</body></html>';
      res.writeHead(200, { 'Content-Type': 'text/html', 'Content-Length': String(body.length) });
      return res.end(body);
    }

    case 'badhash': {
      const b = Buffer.from(real);
      b[b.length - 1] = b[b.length - 1] ^ 0xff;   // same size, different content
      res.writeHead(200, { 'Content-Type': 'application/zip', 'Content-Length': String(b.length) });
      return res.end(b);
    }

    default:
      res.writeHead(400);
      return res.end('unknown mode: ' + mode);
  }
});

server.listen(0, '127.0.0.1', () => {
  process.stdout.write('PORT=' + server.address().port + '\n');
});
