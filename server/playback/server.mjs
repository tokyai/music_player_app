import fs from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {getCapabilities, resolvePlayback} from './sources.mjs';
import {SourceError} from './network.mjs';

const maxRequestBytes = 64 * 1024;

/** 发布已签署的本地解析包；固定文件名和上限，不公开其他服务器文件。 */
async function sendPackageFile(request, response, root, relative, maximum) {
  const file = path.join(root, relative);
  let handle;
  let details;
  try {
    // 发布目录固定，禁止通过父目录链接读取其他服务文件。
    const directories = relative.startsWith('packages/') ? [root, path.join(root, 'packages')] : [root];
    for (const directory of directories) {
      const parent = await fs.promises.lstat(directory);
      if (!parent.isDirectory() || parent.isSymbolicLink()) throw new Error('INVALID_PACKAGE_DIRECTORY');
    }
    const entry = await fs.promises.lstat(file);
    if (!entry.isFile() || entry.isSymbolicLink()) throw new Error('INVALID_PACKAGE_FILE');
    handle = await fs.promises.open(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    // 按已打开的文件检查大小，发布时替换文件不会改变这次响应内容。
    details = await handle.stat();
    if (details.dev !== entry.dev || details.ino !== entry.ino || details.size !== entry.size) {
      throw new Error('PACKAGE_FILE_CHANGED');
    }
  } catch (error) {
    if (handle) await handle.close();
    const status = error.code === 'ENOENT' ? 404 : 503;
    sendJson(response, status, {code: 'PACKAGE_NOT_FOUND', message: '解析包暂不可用'});
    return;
  }
  if (!details.isFile() || details.size < 1 || details.size > maximum) {
    await handle.close();
    sendJson(response, 503, {code: 'INVALID_PACKAGE_FILE', message: '解析包暂不可用'});
    return;
  }
  if (response.destroyed || response.writableEnded) { await handle.close(); return; }
  const stream = handle.createReadStream({highWaterMark: 32 * 1024});
  function cancel() { stream.destroy(); }
  function failed() {
    if (!response.headersSent) sendJson(response, 503, {code: 'PACKAGE_READ_FAILED', message: '解析包读取失败'});
    else response.destroy();
  }
  function cleanup() {
    cancel();
    request.removeListener('aborted', cancel);
    response.removeListener('close', cleanup);
  }
  request.once('aborted', cancel);
  response.once('close', cleanup);
  stream.once('error', failed);
  response.writeHead(200, {'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': details.size, 'Cache-Control': relative === 'manifest.json' ? 'no-store' : 'public, max-age=3600',
    'X-Content-Type-Options': 'nosniff'});
  stream.pipe(response);
}

function sendJson(response, status, body) {
  if (response.destroyed || response.writableEnded) return;
  const json = JSON.stringify(body);
  response.writeHead(status, {'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(json), 'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff'});
  response.end(json);
}

function readRequest(request, signal) {
  return new Promise(function receive(resolve, reject) {
    const chunks = [];
    let length = 0;
    let finished = false;
    const timer = setTimeout(() => finish(new SourceError('REQUEST_TIMEOUT', '解析请求接收超时')), 10000);
    function finish(error) {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      request.removeListener('data', onData);
      request.removeListener('end', onEnd);
      request.removeListener('error', onError);
      signal.removeEventListener('abort', onAbort);
      if (error) {
        request.pause();
        reject(error);
        return;
      }
      try { resolve(JSON.parse(Buffer.concat(chunks, length).toString('utf8'))); }
      catch { reject(new SourceError('INVALID_JSON', '解析请求必须是 JSON 对象')); }
    }
    function onData(chunk) {
      length += chunk.length;
      if (length > maxRequestBytes) {
        finish(new SourceError('REQUEST_TOO_LARGE', '解析请求过大'));
        return;
      }
      chunks.push(chunk);
    }
    function onEnd() { finish(); }
    function onError() { finish(new SourceError('RESOLVE_CANCELLED', '解析请求已断开')); }
    function onAbort() { finish(new SourceError('RESOLVE_CANCELLED', '解析请求已取消')); }
    request.on('data', onData);
    request.once('end', onEnd);
    request.once('error', onError);
    signal.addEventListener('abort', onAbort, {once: true});
    if (signal.aborted) onAbort();
  });
}

function errorStatus(code) {
  if (code === 'REQUEST_TOO_LARGE') return 413;
  if (code === 'REQUEST_TIMEOUT') return 408;
  if (code === 'CREDENTIAL_REQUIRED') return 422;
  if (code.startsWith('INVALID_')) return 400;
  return 502;
}

/**
 * 创建解析服务；测试可传受控 HTTP，生产入口始终要求 TLS。
 * 不排队积累任务，断连会取消当前解析。SHIXIAOYANG，2026/11/20。
 */
export function createPlaybackServer({tls, resolver = resolvePlayback,
  capabilities = getCapabilities, maxConcurrent = 8,
  packageRoot = '/runtime/updates'} = {}) {
  let active = 0;
  const controllers = new Set();
  async function handle(request, response) {
    const controller = new AbortController();
    const disconnect = () => {
      if (!response.writableEnded) controller.abort();
    };
    request.once('aborted', disconnect);
    request.on('error', disconnect);
    response.once('close', disconnect);
    let counted = false;
    try {
      if (request.method === 'GET' && request.url === '/health') {
        sendJson(response, 200, {status: 'ok', protocolVersion: 1});
        return;
      }
      if (request.method === 'GET' && request.url === '/updates/manifest.json') {
        await sendPackageFile(request, response, packageRoot, 'manifest.json', 64 * 1024);
        return;
      }
      const packageMatch = /^\/updates\/packages\/(p[0-9]{6,9}\.json)$/.exec(request.url || '');
      if (request.method === 'GET' && packageMatch) {
        const version = Number(packageMatch[1].slice(1, -5));
        if (version < 1 || packageMatch[1] !== 'p' + String(version).padStart(6, '0') + '.json') {
          sendJson(response, 404, {code: 'PACKAGE_NOT_FOUND', message: '解析包版本路径无效'});
          return;
        }
        await sendPackageFile(request, response, packageRoot, 'packages/' + packageMatch[1], 1024 * 1024);
        return;
      }
      if (request.method === 'GET' && request.url === '/api/sources') {
        sendJson(response, 200, capabilities());
        return;
      }
      if (request.method !== 'POST' || request.url !== '/api/resolve') {
        sendJson(response, 404, {code: 'NOT_FOUND', message: '接口不存在'});
        return;
      }
      if (active >= maxConcurrent) {
        response.setHeader('Retry-After', '2');
        response.setHeader('Connection', 'close');
        sendJson(response, 503, {code: 'SERVER_BUSY', message: '解析服务繁忙，请稍后重试'});
        return;
      }
      if (!/^application\/json(?:;|$)/i.test(request.headers['content-type'] || '')) {
        sendJson(response, 415, {code: 'INVALID_CONTENT_TYPE', message: '解析请求必须使用 JSON'});
        return;
      }
      const declaredLength = Number(request.headers['content-length'] || 0);
      if (declaredLength > maxRequestBytes) {
        response.setHeader('Connection', 'close');
        sendJson(response, 413, {code: 'REQUEST_TOO_LARGE', message: '解析请求过大'});
        return;
      }
      active++;
      counted = true;
      controllers.add(controller);
      const input = await readRequest(request, controller.signal);
      const result = await resolver(input, {signal: controller.signal});
      if (!controller.signal.aborted) sendJson(response, 200, result);
    } catch (error) {
      const code = error instanceof SourceError ? error.code : 'INTERNAL_ERROR';
      const message = error instanceof SourceError ? error.message : '解析服务暂时不可用';
      if (!response.destroyed && !response.headersSent) {
        response.setHeader('Connection', 'close');
        sendJson(response, errorStatus(code), {code, message});
      }
    } finally {
      controller.abort();
      controllers.delete(controller);
      if (counted) active--;
      request.removeListener('aborted', disconnect);
      request.removeListener('error', disconnect);
      response.removeListener('close', disconnect);
    }
  }
  const server = tls ? https.createServer(tls, handle) : http.createServer(handle);
  server.requestTimeout = 12000;
  server.headersTimeout = 10000;
  server.keepAliveTimeout = 5000;
  server.maxConnections = 32;
  // 协议错误和半包不交给默认未处理异常路径。
  server.on('clientError', (_error, socket) => socket.destroy());
  server.on('close', () => {
    for (const controller of controllers) controller.abort();
  });
  server.cancelPlaybackRequests = () => {
    for (const controller of controllers) controller.abort();
  };
  return server;
}

function start() {
  const keyPath = process.env.PLAYBACK_TLS_KEY || '/runtime/tls/server.key';
  const certPath = process.env.PLAYBACK_TLS_CERT || '/runtime/tls/server.crt';
  const tls = {key: fs.readFileSync(keyPath), cert: fs.readFileSync(certPath), minVersion: 'TLSv1.2'};
  const server = createPlaybackServer({tls});
  const port = Number(process.env.PORT || 8443);
  server.once('error', () => {
    console.error('解析服务监听失败，请检查端口配置');
    process.exitCode = 1;
  });
  server.listen(port, process.env.LISTEN_HOST || '0.0.0.0', () => console.log(`音乐解析服务已启动，端口 ${port}`));
  function stop() {
    server.cancelPlaybackRequests();
    server.close();
    server.closeAllConnections();
  }
  process.once('SIGTERM', stop);
  process.once('SIGINT', stop);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try { start(); }
  catch { console.error('解析服务启动失败，请检查 TLS 文件和端口配置'); process.exitCode = 1; }
}
