/** 共用 HTTPS 入口与证书续期。SHIXIAOYANG，2026/11/20。 */
import fs from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import tls from 'node:tls';
import {pathToFileURL} from 'node:url';

const prefix = '/music-player-api/';
const hopHeaders = new Set(['connection', 'proxy-connection', 'keep-alive', 'te',
  'trailer', 'transfer-encoding', 'upgrade', 'proxy-authenticate', 'proxy-authorization']);

class ProxyError extends Error {
  constructor(code) { super(code); this.code = code; }
}

function forwardedHeaders(headers) {
  const excluded = new Set(hopHeaders);
  for (const token of String(headers.connection || '').split(',')) excluded.add(token.trim().toLowerCase());
  const result = {};
  for (const [key, value] of Object.entries(headers)) {
    if (!excluded.has(key.toLowerCase()) && value !== undefined) result[key] = value;
  }
  return result;
}

function optionsFor(request, target, path, ca) {
  return {protocol: target.protocol, hostname: target.hostname, port: target.port,
    path, method: request.method, headers: forwardedHeaders(request.headers), agent: false,
    rejectUnauthorized: true, ca,
    // 上游拨号走本机，证书仍必须代表公网入口的 IP 身份。
    checkServerIdentity: (_host, certificate) => tls.checkServerIdentity('137.175.62.3', certificate)};
}

function transport(target) { return target.protocol === 'https:' ? https : http; }

function fail(response, error) {
  if (response.destroyed || response.writableEnded) return;
  if (response.headersSent) { response.destroy(); return; }
  const timeout = error?.code === 'TIMEOUT';
  const oversized = error?.code === 'REQUEST_TOO_LARGE';
  const status = oversized ? 413 : (timeout ? 504 : 502);
  const body = JSON.stringify({code: error?.code || 'UPSTREAM_UNAVAILABLE',
    message: oversized ? '解析请求过大' : (timeout ? '解析请求超时' : '服务暂时不可用')});
  response.writeHead(status, {'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body), 'Connection': 'close'});
  response.end(body);
}

function boundedBody(stream, maximum, signal, code) {
  return new Promise(function receive(resolve, reject) {
    const chunks = [];
    let length = 0;
    let finished = false;
    function finish(error) {
      if (finished) return;
      finished = true;
      stream.removeListener('data', onData);
      stream.removeListener('end', onEnd);
      stream.removeListener('error', onError);
      stream.removeListener('aborted', onError);
      signal.removeEventListener('abort', onAbort);
      if (error) { stream.pause(); reject(error); }
      else resolve(Buffer.concat(chunks, length));
    }
    function onData(chunk) {
      length += chunk.length;
      if (length > maximum) { finish(new ProxyError(code)); return; }
      chunks.push(chunk);
    }
    function onEnd() { finish(); }
    function onError() { finish(new ProxyError('UPSTREAM_UNAVAILABLE')); }
    function onAbort() { finish(signal.reason || new ProxyError('CANCELLED')); }
    stream.on('data', onData);
    stream.once('end', onEnd);
    stream.once('error', onError);
    stream.once('aborted', onError);
    signal.addEventListener('abort', onAbort, {once: true});
    if (signal.aborted) onAbort();
  });
}

function upstreamResponse(outgoing, signal) {
  return new Promise(function receive(resolve, reject) {
    function cancel() { outgoing.destroy(signal.reason || new ProxyError('CANCELLED')); }
    function response(value) { signal.removeEventListener('abort', cancel); resolve(value); }
    function failed(error) { signal.removeEventListener('abort', cancel); reject(error); }
    outgoing.once('response', response);
    outgoing.once('error', failed);
    signal.addEventListener('abort', cancel, {once: true});
    if (signal.aborted) cancel();
  });
}

async function musicRequest(request, response, target, ca, active, timeoutMs) {
  const path = '/' + request.url.slice(prefix.length);
  const allowed = (request.method === 'GET' && ['/health', '/api/sources'].includes(path)) ||
    (request.method === 'POST' && path === '/api/resolve');
  if (!allowed) { response.writeHead(404); response.end(); return; }
  const controller = new AbortController();
  let outgoing;
  let upstream;
  function cancel() { controller.abort(new ProxyError('CANCELLED')); outgoing?.destroy(); upstream?.destroy(); }
  function disconnected() { if (!response.writableEnded) cancel(); }
  active.add(cancel);
  request.once('aborted', cancel);
  request.on('error', cancel);
  response.once('close', disconnected);
  const timer = setTimeout(() => controller.abort(new ProxyError('TIMEOUT')), timeoutMs);
  try {
    if (Number(request.headers['content-length'] || 0) > 64 * 1024) throw new ProxyError('REQUEST_TOO_LARGE');
    const body = await boundedBody(request, 64 * 1024, controller.signal, 'REQUEST_TOO_LARGE');
    const options = optionsFor(request, target, path, ca);
    options.headers['content-length'] = body.length;
    outgoing = transport(target).request(options);
    const received = upstreamResponse(outgoing, controller.signal);
    outgoing.end(body);
    upstream = await received;
    if (upstream.statusCode >= 300 && upstream.statusCode < 400) throw new ProxyError('UPSTREAM_REDIRECT');
    const content = await boundedBody(upstream, 512 * 1024, controller.signal, 'RESPONSE_TOO_LARGE');
    if (controller.signal.aborted) throw controller.signal.reason;
    response.writeHead(upstream.statusCode || 502, forwardedHeaders(upstream.headers));
    response.end(content);
  } catch (error) {
    fail(response, error);
  } finally {
    clearTimeout(timer);
    cancel();
    active.delete(cancel);
    request.removeListener('aborted', cancel);
    request.removeListener('error', cancel);
    response.removeListener('close', disconnected);
  }
}

function siteRequest(request, response, target, ca, active) {
  const outgoing = transport(target).request(optionsFor(request, target, request.url, ca));
  let upstream;
  function cancel() { outgoing.destroy(); upstream?.destroy(); }
  function cleanup() {
    cancel();
    active.delete(cancel);
    request.removeListener('aborted', cancel);
    request.removeListener('error', cancel);
  }
  active.add(cancel);
  request.once('aborted', cancel);
  request.on('error', cancel);
  response.once('close', cleanup);
  outgoing.on('error', error => fail(response, error));
  outgoing.once('response', function received(value) {
    upstream = value;
    if (response.destroyed || response.writableEnded) { upstream.destroy(); return; }
    upstream.on('error', () => response.destroy());
    upstream.once('aborted', () => response.destroy());
    response.writeHead(upstream.statusCode || 502, forwardedHeaders(upstream.headers));
    // 原站可能返回大文件或长流；保留背压，不复制整份内容或限制其业务时长。
    upstream.pipe(response);
  });
  request.pipe(outgoing);
}

function writeUpgradeHeaders(socket, response) {
  let head = `HTTP/${response.httpVersion} ${response.statusCode} ${response.statusMessage}\r\n`;
  for (let index = 0; index < response.rawHeaders.length; index += 2) {
    head += `${response.rawHeaders[index]}: ${response.rawHeaders[index + 1]}\r\n`;
  }
  socket.write(head + '\r\n');
}

function siteUpgrade(request, socket, head, target, ca, active) {
  if (request.url.startsWith(prefix)) { socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n'); return; }
  const options = optionsFor(request, target, request.url, ca);
  options.headers.connection = 'Upgrade';
  options.headers.upgrade = request.headers.upgrade;
  const outgoing = transport(target).request(options);
  let tunnel;
  function close() { outgoing.destroy(); tunnel?.destroy(); socket.destroy(); active.delete(close); }
  active.add(close);
  socket.on('error', close);
  socket.once('close', close);
  outgoing.on('error', close);
  outgoing.once('upgrade', function upgraded(response, upstreamSocket, upstreamHead) {
    tunnel = upstreamSocket;
    tunnel.on('error', close);
    tunnel.once('close', close);
    if (socket.destroyed) { close(); return; }
    writeUpgradeHeaders(socket, response);
    if (head.length) tunnel.write(head);
    if (upstreamHead.length) socket.write(upstreamHead);
    socket.pipe(tunnel);
    tunnel.pipe(socket);
  });
  outgoing.once('response', function rejected(response) {
    response.on('error', close);
    writeUpgradeHeaders(socket, response);
    response.pipe(socket);
  });
  outgoing.end();
}

function checkedTarget(value, testOnlyHttp) {
  const target = new URL(value);
  const allowed = target.protocol === 'https:' || (testOnlyHttp && target.protocol === 'http:');
  if (!allowed || target.username || target.password || target.hash || target.search || target.pathname !== '/') {
    throw new Error('固定上游地址无效');
  }
  return target;
}

/** 创建共用 HTTPS 入口，音乐接口有界转发，原站和 WebSocket 保持流式。 */
export function createFrontProxy({tls: certificates, musicUpstream = 'https://127.0.0.1:9443/',
  siteUpstream = 'https://127.0.0.1:8444/', musicCa, siteCa, testOnlyHttp = false, timeoutMs = 24000} = {}) {
  const music = checkedTarget(musicUpstream, testOnlyHttp);
  const site = checkedTarget(siteUpstream, testOnlyHttp);
  const active = new Set();
  const siteTrust = siteCa ? [...tls.rootCertificates, siteCa] : undefined;
  function handle(request, response) {
    response.on('error', () => response.destroy());
    if (request.url.startsWith(prefix)) {
      musicRequest(request, response, music, musicCa, active, timeoutMs).catch(error => fail(response, error));
    } else {
      try { siteRequest(request, response, site, siteTrust, active); }
      catch (error) { fail(response, error); }
    }
  }
  const server = certificates ? https.createServer(certificates, handle) : http.createServer(handle);
  server.maxConnections = 32;
  server.headersTimeout = 10000;
  server.requestTimeout = 0;
  server.on('clientError', (_error, socket) => socket.destroy());
  server.on('upgrade', function upgrade(request, socket, head) {
    try { siteUpgrade(request, socket, head, site, siteTrust, active); }
    catch { socket.destroy(); }
  });
  server.cancelProxyRequests = () => { for (const cancel of active) cancel(); };
  return server;
}

/** 定期读取原子续期后的证书，失败保留上一有效 TLS 身份。 */
export function createCertificateReloader(server, {keyPath, certPath, intervalMs = 60000,
  stat = fs.statSync, read = fs.readFileSync, validate = tls.createSecureContext,
  onFailure = () => console.error('入口证书续期加载失败，继续使用上一有效证书')} = {}) {
  let lastStamp = `${stat(keyPath).mtimeMs}:${stat(certPath).mtimeMs}`;
  let failed = false;
  function check() {
    try {
      const stamp = `${stat(keyPath).mtimeMs}:${stat(certPath).mtimeMs}`;
      if (stamp === lastStamp) return;
      const credentials = {key: read(keyPath), cert: read(certPath), minVersion: 'TLSv1.2'};
      validate(credentials);
      server.setSecureContext(credentials);
      lastStamp = stamp;
      failed = false;
    } catch {
      if (!failed) onFailure();
      failed = true;
    }
  }
  const timer = setInterval(check, intervalMs);
  timer.unref();
  return {check, close() { clearInterval(timer); }};
}

function start() {
  const keyPath = process.env.FRONT_TLS_KEY || '/runtime/tls/front.key';
  const certPath = process.env.FRONT_TLS_CERT || '/runtime/tls/front.crt';
  const musicCaPath = process.env.MUSIC_API_CA || '/runtime/tls/music-api.crt';
  const siteCaPath = process.env.SITE_CA;
  const server = createFrontProxy({tls: {key: fs.readFileSync(keyPath), cert: fs.readFileSync(certPath), minVersion: 'TLSv1.2'},
    musicCa: fs.readFileSync(musicCaPath), siteCa: siteCaPath ? fs.readFileSync(siteCaPath) : undefined});
  const certificates = createCertificateReloader(server, {keyPath, certPath});
  server.once('error', () => { certificates.close(); console.error('入口监听失败，请检查端口和证书配置'); process.exitCode = 1; });
  const port = Number(process.env.PORT || 8443);
  server.listen(port, '0.0.0.0', () => console.log(`共用 HTTPS 入口已启动，端口 ${port}`));
  function stop() { certificates.close(); server.cancelProxyRequests(); server.close(); server.closeAllConnections(); }
  process.once('SIGTERM', stop);
  process.once('SIGINT', stop);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try { start(); }
  catch { console.error('入口启动失败，请检查固定上游和 TLS 配置'); process.exitCode = 1; }
}
