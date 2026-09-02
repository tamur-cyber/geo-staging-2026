#!/usr/bin/env node
/**
 * A real HTTP stand-in for the GitHub Releases API, for the tag-collision test.
 *
 * scripts/publish-release.sh talks to $GITHUB_API_URL, which GitHub Actions sets
 * to https://api.github.com. Pointing it here exercises the SHIPPED script over
 * real HTTP with real bytes -- the collision decision is made by downloading the
 * published asset and hashing it, so this server must serve genuine bytes.
 *
 * FAKE_API_MODE:
 *   absent     no release on the tag  -> the script should create and upload
 *   identical  a release whose assets are the real committed files
 *   differ     a release whose assets have one byte flipped: same name, same
 *              size, different sha256. The collision must be caught by content,
 *              which a name or size comparison could not do.
 */
const http = require('http');
const fs = require('fs');
const path = require('path');

const MODE = process.env.FAKE_API_MODE || 'absent';
const DATA_DIR = process.env.FAKE_ORIGIN_DATA || path.join(__dirname, '..', 'data');
const SOURCES = JSON.parse(fs.readFileSync(process.env.FAKE_API_SOURCES
  || path.join(__dirname, '..', 'sources.json'), 'utf8')).sources;

let base = '';
const uploaded = [];

function assetBytes(name) {
  const real = fs.readFileSync(path.join(DATA_DIR, name));
  if (MODE !== 'differ') return real;
  const b = Buffer.from(real);
  b[b.length - 1] = b[b.length - 1] ^ 0xff;
  return b;
}

const server = http.createServer((req, res) => {
  const url = req.url.split('?')[0];
  const json = (code, obj) => {
    const body = JSON.stringify(obj);
    res.writeHead(code, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) });
    res.end(body);
  };

  // GET /repos/:owner/:repo/releases/tags/:tag
  if (req.method === 'GET' && /\/releases\/tags\//.test(url)) {
    if (MODE === 'absent') return json(404, { message: 'Not Found' });
    return json(200, {
      id: 1,
      tag_name: url.split('/').pop(),
      upload_url: base + '/uploads/1/assets{?name,label}',
      assets: SOURCES.map((s, i) => ({
        id: i + 1,
        name: s.name,
        size: s.bytes,
        url: base + '/assets/' + s.name,
        browser_download_url: base + '/download/' + s.name,
      })),
    });
  }

  // GET the asset bytes (the script downloads to compare, it does not trust a field)
  if (req.method === 'GET' && url.startsWith('/assets/')) {
    const name = decodeURIComponent(url.slice('/assets/'.length));
    let b;
    try { b = assetBytes(name); } catch { return json(404, { message: 'no such asset' }); }
    res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Length': String(b.length) });
    return res.end(b);
  }

  // POST /repos/:owner/:repo/releases
  if (req.method === 'POST' && /\/releases$/.test(url)) {
    let body = '';
    req.on('data', (c) => { body += c; });
    return req.on('end', () => {
      let parsed = {};
      try { parsed = JSON.parse(body); } catch { /* recorded as empty */ }
      json(201, {
        id: 1,
        tag_name: parsed.tag_name,
        name: parsed.name,
        upload_url: base + '/uploads/1/assets{?name,label}',
        assets: [],
      });
    });
  }

  // POST the upload endpoint
  if (req.method === 'POST' && url.startsWith('/uploads/')) {
    const name = new URL(req.url, base).searchParams.get('name');
    let bytes = 0;
    req.on('data', (c) => { bytes += c.length; });
    return req.on('end', () => {
      uploaded.push({ name, bytes });
      fs.appendFileSync(process.env.FAKE_API_UPLOAD_LOG || '/dev/null', `${name} ${bytes}\n`);
      json(201, { id: uploaded.length, name, size: bytes });
    });
  }

  json(404, { message: 'unrouted: ' + req.method + ' ' + url });
});

server.listen(0, '127.0.0.1', () => {
  base = 'http://127.0.0.1:' + server.address().port;
  process.stdout.write('PORT=' + server.address().port + '\n');
});
