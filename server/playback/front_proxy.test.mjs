import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import tls from 'node:tls';
import {X509Certificate} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {once} from 'node:events';
import test from 'node:test';
import {createCertificateReloader, createFrontProxy} from './front_proxy.mjs';

async function serve(t, handler) {
  const server = http.createServer(handler);
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(function cleanup() { server.closeAllConnections(); server.close(); });
  return {server, base: `http://127.0.0.1:${server.address().port}/`};
}

async function fixture(t, {music, site, timeoutMs} = {}) {
  const musicServer = await serve(t, music || function musicDefault(_request, response) { response.end('{"status":"ok"}'); });
  const siteServer = await serve(t, site || function siteDefault(request, response) { response.end(`site:${request.url}`); });
  const proxy = createFrontProxy({musicUpstream: musicServer.base, siteUpstream: siteServer.base, testOnlyHttp: true, timeoutMs});
  proxy.listen(0, '127.0.0.1');
  await once(proxy, 'listening');
  t.after(function cleanupProxy() { proxy.cancelProxyRequests(); proxy.closeAllConnections(); proxy.close(); });
  return {proxy, music: musicServer.server, site: siteServer.server,
    base: `http://127.0.0.1:${proxy.address().port}`};
}

function responseBody(response) {
  return new Promise(function read(resolve, reject) {
    const chunks = [];
    response.on('data', chunk => chunks.push(chunk));
    response.once('end', () => resolve(Buffer.concat(chunks)));
    response.once('error', reject);
  });
}

test('music prefix routes to fixed API and original routes retain their exact path', async function prefixRouting(t) {
  const requested = [];
  const front = await fixture(t, {music: function music(request, response) { requested.push(request.url); response.end('{}'); }});
  assert.equal((await fetch(`${front.base}/music-player-api/api/sources`)).status, 200);
  assert.deepEqual(requested, ['/api/sources']);
  assert.equal(await (await fetch(`${front.base}/path?a=b`)).text(), 'site:/path?a=b');
});

test('unsupported API methods, traversal and redirects never select an arbitrary upstream', async function apiBoundary(t) {
  let calls = 0;
  const front = await fixture(t, {music: function count(_request, response) { calls++; response.end('{}'); }});
  for (const path of ['/music-player-api/api/other', '/music-player-api/api/sources?target=http://evil', '/music-player-api/%2e%2e/private']) {
    const response = await rawGet(front.base + path);
    assert.equal(response.statusCode, 404);
    response.resume();
  }
  assert.equal((await fetch(`${front.base}/music-player-api/api/resolve`, {method: 'PUT'})).status, 404);
  assert.equal(calls, 0);
});

function rawGet(url) {
  const address = new URL(url);
  // 直接提供原始 path，让边界测试不会被 URL 构造器提前归一化。
  const path = url.slice(address.origin.length);
  return new Promise(function receive(resolve, reject) {
    http.get({hostname: address.hostname, port: address.port, path}, resolve).once('error', reject);
  });
}

test('original POST preserves body, Host, Authorization and Cookie', async function sitePost(t) {
  let received;
  const front = await fixture(t, {site: async function site(request, response) {
    const body = await responseBody(request);
    received = {path: request.url, method: request.method, host: request.headers.host,
      authorization: request.headers.authorization, cookie: request.headers.cookie, body: body.toString()};
    response.writeHead(201, {'Set-Cookie': ['session=updated; HttpOnly']});
    response.end('saved');
  }});
  const response = await new Promise(function send(resolve, reject) {
    const request = http.request(`${front.base}/login?next=/home`, {method: 'POST', headers:
      {Host: '137.175.62.3:8443', Authorization: 'Bearer personal-token', Cookie: 'session=existing', 'Content-Type': 'text/plain'}}, resolve);
    request.once('error', reject);
    request.end('original body');
  });
  assert.equal(response.statusCode, 201);
  assert.deepEqual(response.headers['set-cookie'], ['session=updated; HttpOnly']);
  await responseBody(response);
  assert.deepEqual(received, {path: '/login?next=/home', method: 'POST', host: '137.175.62.3:8443',
    authorization: 'Bearer personal-token', cookie: 'session=existing', body: 'original body'});
});

test('original redirects and streaming large responses are preserved', async function siteStreaming(t) {
  const content = Buffer.alloc(1024 * 1024, 'x');
  const front = await fixture(t, {site: function site(request, response) {
    if (request.url === '/redirect') { response.writeHead(302, {Location: '/destination'}); response.end(); return; }
    response.writeHead(200, {'Content-Type': 'application/octet-stream'});
    response.write(content.subarray(0, 128));
    setTimeout(function remaining() { response.end(content.subarray(128)); }, 20);
  }});
  const redirected = await fetch(`${front.base}/redirect`, {redirect: 'manual'});
  assert.equal(redirected.status, 302);
  assert.equal(redirected.headers.get('location'), '/destination');
  const response = await rawGet(`${front.base}/large-file`);
  const first = await once(response, 'data');
  assert.equal(first[0].length, 128);
  const remaining = await responseBody(response);
  assert.equal(remaining.length + 128, content.length);
});

test('music POST forwards unchanged JSON and enforces request size', async function musicPost(t) {
  const bodies = [];
  const front = await fixture(t, {music: async function music(request, response) {
    bodies.push((await responseBody(request)).toString());
    response.end('{}');
  }});
  const body = '{"platform":"163","id":"song"}';
  assert.equal((await fetch(`${front.base}/music-player-api/api/resolve`, {method: 'POST', body})).status, 200);
  assert.deepEqual(bodies, [body]);
  const oversized = await fetch(`${front.base}/music-player-api/api/resolve`, {method: 'POST', body: 'x'.repeat(65537)});
  assert.equal(oversized.status, 413);
  assert.equal(bodies.length, 1);
});

test('music oversized chunked input is rejected before contacting backend', async function chunkedInput(t) {
  let calls = 0;
  const front = await fixture(t, {music: function music(_request, response) { calls++; response.end('{}'); }});
  const response = await new Promise(function send(resolve, reject) {
    const request = http.request(`${front.base}/music-player-api/api/resolve`, {method: 'POST', headers: {'Transfer-Encoding': 'chunked'}}, resolve);
    request.once('error', reject);
    request.end('x'.repeat(65537));
  });
  assert.equal(response.statusCode, 413);
  await responseBody(response);
  assert.equal(calls, 0);
});

test('music response limit and redirect refusal return bounded failures', async function boundedResponse(t) {
  const front = await fixture(t, {music: function music(request, response) {
    if (request.url === '/health') { response.writeHead(302, {Location: 'https://untrusted.example/'}); response.end(); return; }
    response.end('x'.repeat(512 * 1024 + 1));
  }});
  const large = await fetch(`${front.base}/music-player-api/api/sources`);
  assert.equal(large.status, 502);
  assert.equal((await large.json()).code, 'RESPONSE_TOO_LARGE');
  const redirected = await fetch(`${front.base}/music-player-api/health`);
  assert.equal(redirected.status, 502);
  assert.equal((await redirected.json()).code, 'UPSTREAM_REDIRECT');
  assert.equal(redirected.headers.get('location'), null);
});

test('music total deadline cancels an upstream that never answers', async function deadline(t) {
  let ended;
  const cancelled = new Promise(resolve => { ended = resolve; });
  const front = await fixture(t, {timeoutMs: 30, music: function slow(_request, response) { response.once('close', ended); }});
  const response = await fetch(`${front.base}/music-player-api/health`);
  assert.equal(response.status, 504);
  await cancelled;
});

test('disconnecting a music client releases upstream response and leaves original site usable', async function cancellation(t) {
  let begin;
  let end;
  const begun = new Promise(resolve => { begin = resolve; });
  const ended = new Promise(resolve => { end = resolve; });
  const front = await fixture(t, {music: function slow(_request, response) {
    response.once('close', end);
    response.writeHead(200);
    response.write('{');
    begin();
  }});
  const request = http.get(`${front.base}/music-player-api/health`);
  request.on('error', () => {});
  await begun;
  request.destroy();
  await ended;
  assert.equal(await (await fetch(`${front.base}/other`)).text(), 'site:/other');
});

test('original WebSocket upgrade forwards headers and both early data buffers', async function websocket(t) {
  const front = await fixture(t);
  const upstreamSockets = new Set();
  front.site.on('upgrade', function upgrade(request, socket, head) {
    upstreamSockets.add(socket);
    socket.once('close', () => upstreamSockets.delete(socket));
    socket.once('end', () => socket.end());
    assert.equal(request.url, '/socket?channel=original');
    assert.equal(request.headers.cookie, 'session=original');
    assert.equal(request.headers.host, '137.175.62.3:8443');
    socket.write('HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\nwelcome');
    if (head.length) socket.write(head);
    socket.on('data', chunk => socket.write(chunk));
  });
  t.after(function cleanupTunnels() { for (const socket of upstreamSockets) socket.destroy(); });
  const socket = net.createConnection(front.proxy.address().port, '127.0.0.1');
  t.after(() => socket.destroy());
  await once(socket, 'connect');
  const received = [];
  socket.on('data', chunk => received.push(chunk));
  socket.write('GET /socket?channel=original HTTP/1.1\r\nHost: 137.175.62.3:8443\r\nCookie: session=original\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\nearly');
  await until(function complete() { return Buffer.concat(received).toString().includes('welcomeearly'); });
  assert.match(Buffer.concat(received).toString(), /^HTTP\/1\.1 101 Switching Protocols/);
  socket.write('bidirectional');
  await until(function echoed() { return Buffer.concat(received).toString().includes('bidirectional'); });
  socket.destroy();
  await until(function closed() { return upstreamSockets.size === 0; });
});

async function until(condition) {
  const deadline = Date.now() + 2000;
  while (!condition()) {
    if (Date.now() >= deadline) throw new Error('等待代理状态超时');
    await new Promise(resolve => setTimeout(resolve, 5));
  }
}

test('fixed upstream configuration disallows plaintext production targets and embedded credentials', function fixedTargets() {
  assert.throws(() => createFrontProxy({musicUpstream: 'http://127.0.0.1:9443/'}));
  assert.throws(() => createFrontProxy({siteUpstream: 'https://user:password@127.0.0.1:8444/'}));
});

test('certificate reload applies only changed valid files and retains context after failure', function certificateReload() {
  assert.equal(typeof https.createServer().setSecureContext, 'function');
  let stamp = 1;
  let valid = true;
  let reads = 0;
  let warnings = 0;
  const applied = [];
  const server = {setSecureContext(value) { applied.push(value); }};
  const loader = createCertificateReloader(server, {keyPath: 'key', certPath: 'cert',
    stat: function stat() { return {mtimeMs: stamp}; },
    read: function read(path) { reads++; return `${path}${stamp}`; },
    validate: function validate() { if (!valid) throw new Error('invalid cert'); },
    onFailure: function warn() { warnings++; }});
  try {
    loader.check();
    assert.equal(reads, 0);
    stamp = 2;
    loader.check();
    assert.equal(applied.length, 1);
    assert.equal(applied[0].key, 'key2');
    valid = false;
    stamp = 3;
    loader.check();
    loader.check();
    assert.equal(applied.length, 1);
    assert.equal(warnings, 1);
    valid = true;
    stamp = 4;
    loader.check();
    assert.equal(applied.length, 2);
    assert.equal(applied[1].cert, 'cert4');
  } finally { loader.close(); }
});

function certificateFixtures(t) {
  const binary = process.env.OPENSSL_TEST_BINARY || (process.platform === 'win32' ?
    'C:/Program Files/Git/usr/bin/openssl.exe' : '/usr/bin/openssl');
  if (!fs.existsSync(binary)) { t.skip('本机未提供 OpenSSL，真实证书回归需设置 OPENSSL_TEST_BINARY'); return null; }
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'kuzai-proxy-tls-'));
  t.after(function cleanupCertificates() {
    const resolved = path.resolve(directory);
    assert.equal(path.dirname(resolved), path.resolve(os.tmpdir()));
    assert.ok(path.basename(resolved).startsWith('kuzai-proxy-tls-'));
    fs.rmSync(resolved, {recursive: true, force: true});
  });
  function create(name, ip) {
    const keyPath = path.join(directory, `${name}.key`);
    const certPath = path.join(directory, `${name}.crt`);
    execFileSync(binary, ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
      '-keyout', keyPath, '-out', certPath, '-subj', `/CN=${ip}`, '-addext', `subjectAltName=IP:${ip}`],
    {stdio: ['ignore', 'pipe', 'pipe']});
    return {keyPath, certPath, key: fs.readFileSync(keyPath), cert: fs.readFileSync(certPath)};
  }
  return {first: create('first', '137.175.62.3'), second: create('second', '137.175.62.3'),
    wrongIdentity: create('wrong', '127.0.0.1')};
}

async function serveTls(t, credentials) {
  const server = https.createServer(credentials, function site(_request, response) { response.end('trusted'); });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(function cleanup() { server.closeAllConnections(); server.close(); });
  return `https://127.0.0.1:${server.address().port}/`;
}

async function listenProxy(t, options) {
  const server = createFrontProxy(options);
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(function cleanup() { server.cancelProxyRequests(); server.closeAllConnections(); server.close(); });
  return server;
}

function tlsResponse(server, route, authorities) {
  return new Promise(function request(resolve, reject) {
    const options = {hostname: '127.0.0.1', port: server.address().port, path: route, agent: false,
      ca: authorities, checkServerIdentity: (_host, certificate) => tls.checkServerIdentity('137.175.62.3', certificate)};
    https.get(options, async function received(response) {
      const fingerprint = response.socket.getPeerCertificate().fingerprint256;
      try { resolve({status: response.statusCode, body: (await responseBody(response)).toString(), fingerprint}); }
      catch (error) { reject(error); }
    }).once('error', reject);
  });
}

test('real TLS validates fixed upstream identity and reloads an atomically replaced certificate', async function realTlsRenewal(t) {
  const fixtures = certificateFixtures(t);
  if (!fixtures) return;
  const music = await serveTls(t, fixtures.first);
  const site = await serveTls(t, fixtures.first);
  const options = {tls: fixtures.first, musicUpstream: music, siteUpstream: site,
    musicCa: fixtures.first.cert, siteCa: fixtures.first.cert};
  const proxy = await listenProxy(t, options);
  const trust = [fixtures.first.cert, fixtures.second.cert];
  const first = await tlsResponse(proxy, '/music-player-api/health', trust);
  assert.equal(first.status, 200);
  assert.equal(first.body, 'trusted');
  assert.equal((await tlsResponse(proxy, '/original', trust)).status, 200);
  const loader = createCertificateReloader(proxy, {keyPath: fixtures.first.keyPath, certPath: fixtures.first.certPath});
  try {
    fs.writeFileSync(fixtures.first.keyPath, fixtures.second.key);
    fs.writeFileSync(fixtures.first.certPath, fixtures.second.cert);
    loader.check();
    const renewed = await tlsResponse(proxy, '/music-player-api/health', trust);
    assert.equal(renewed.status, 200);
    assert.equal(renewed.fingerprint, new X509Certificate(fixtures.second.cert).fingerprint256);
    assert.notEqual(renewed.fingerprint, first.fingerprint);
  } finally { loader.close(); }
  const untrustedIdentity = await serveTls(t, fixtures.wrongIdentity);
  const wrong = await listenProxy(t, {...options, musicUpstream: untrustedIdentity, musicCa: fixtures.wrongIdentity.cert});
  const refused = await tlsResponse(wrong, '/music-player-api/health', trust);
  assert.equal(refused.status, 502);
  assert.equal(JSON.parse(refused.body).code, 'ERR_TLS_CERT_ALTNAME_INVALID');
});
