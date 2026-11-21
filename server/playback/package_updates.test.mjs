import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import {once} from 'node:events';
import test from 'node:test';
import {createPlaybackServer} from './server.mjs';
import {createFrontProxy} from './front_proxy.mjs';
import {buildPlaybackPackage} from '../../tools/build_playback_package.mjs';
import {inspectPlaybackPackage, installPlaybackPackage, verifyPackageManifest} from '../../tools/install_playback_package.mjs';

// 仅使用本轮测试身份，真实发布私钥和服务器凭据不参与回归。SHIXIAOYANG，2026/11/21。
const identity = crypto.generateKeyPairSync('ed25519');
const publicKeyBase64 = identity.publicKey.export({type: 'spki', format: 'der'}).subarray(12).toString('base64');
const maximumPackageBytes = 1024 * 1024;

function temporary(t) {
  const parent = fs.realpathSync(os.tmpdir());
  const root = fs.mkdtempSync(path.join(parent, 'kuzai-package-updates-'));
  t.after(function cleanup() {
    const resolved = fs.realpathSync(root);
    assert.equal(path.dirname(resolved), parent);
    assert.ok(path.basename(resolved).startsWith('kuzai-package-updates-'));
    fs.rmSync(resolved, {recursive: true, force: true});
  });
  return root;
}

function bundle(version) {
  return {packageFormat: 1, packageVersion: version, minimumBridgeVersion: 1,
    capabilities: {protocolVersion: 1, revision: 'p' + String(version).padStart(6, '0'),
      sources: [{id: 'test_source', name: '测试音源', description: '', platforms: ['163'], credentials: []}]},
    allowedOrigins: ['https://audio.example'], script: 'var KuzaiSources = {};'};
}

function signedManifest(payload, signer = identity.privateKey) {
  const bytes = Buffer.from(JSON.stringify(payload));
  return Buffer.from(JSON.stringify({payloadBase64: bytes.toString('base64'),
    signatureBase64: crypto.sign(null, bytes, signer).toString('base64')}));
}

function release(parent, version, overrides = {}) {
  const root = path.join(parent, 'stage-' + version + '-' + crypto.randomBytes(4).toString('hex'));
  fs.mkdirSync(path.join(root, 'packages'), {recursive: true});
  const packagePath = 'packages/p' + String(version).padStart(6, '0') + '.json';
  const bytes = Buffer.from(JSON.stringify(overrides.bundle || bundle(version)));
  const payload = {packageFormat: 1, packageVersion: version, minimumBridgeVersion: 1,
    packagePath, bytes: bytes.length, sha256: crypto.createHash('sha256').update(bytes).digest('hex'), ...overrides.payload};
  const manifest = signedManifest(payload, overrides.signer);
  fs.writeFileSync(path.join(root, packagePath), bytes);
  fs.writeFileSync(path.join(root, 'manifest.json'), manifest);
  return {root, manifest, packagePath, bytes, payload};
}

function install(incoming, destinationRoot) {
  return installPlaybackPackage({stagingRoot: incoming.root, destinationRoot, publicKeyBase64});
}

function current(root) { return fs.readFileSync(path.join(root, 'manifest.json')); }

function unchanged(root, expected) {
  assert.deepEqual(current(root), expected);
  assert.equal(fs.existsSync(path.join(root, '.publish.lock')), false);
  assert.equal(fs.readdirSync(root).some(function part(name) { return name.endsWith('.part'); }), false);
  assert.equal(fs.readdirSync(path.join(root, 'packages')).some(function part(name) { return name.endsWith('.part'); }), false);
}

async function listen(t, server) {
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(async function cleanup() {
    server.cancelProxyRequests?.();
    server.cancelPlaybackRequests?.();
    server.closeAllConnections();
    await new Promise(function closed(resolve) { server.close(resolve); });
  });
  return server;
}

async function server(t, root, options = {}) {
  return listen(t, createPlaybackServer({packageRoot: root, ...options}));
}

function request(server, route, method = 'GET') {
  return new Promise(function receive(resolve, reject) {
    const outgoing = http.request({hostname: '127.0.0.1', port: server.address().port,
      path: route, method, agent: false}, function received(response) {
      const chunks = [];
      response.on('data', function data(chunk) { chunks.push(chunk); });
      response.once('end', function end() { resolve({status: response.statusCode, headers: response.headers, body: Buffer.concat(chunks)}); });
      response.once('error', reject);
    });
    outgoing.setTimeout(2000, function timeout() { outgoing.destroy(new Error('本地更新测试超时')); });
    outgoing.once('error', reject);
    outgoing.end();
  });
}

function link(t, target, destination, directory = false) {
  try { fs.symlinkSync(target, destination, directory ? (process.platform === 'win32' ? 'junction' : 'dir') : 'file'); }
  catch (error) {
    if (process.platform !== 'win32' || !['EPERM', 'EACCES'].includes(error.code)) throw error;
    t.skip('Windows 未授予文件符号链接权限；Linux/授权本机需执行本测试');
    return false;
  }
  return true;
}

test('static updates preserve signed bytes and never invoke playback resolution', async function staticBytes(t) {
  const incoming = release(temporary(t), 1);
  let resolutions = 0;
  let capabilities = 0;
  function resolve() { resolutions++; throw new Error('静态更新不能解析音乐'); }
  function catalog() { capabilities++; throw new Error('静态更新不能读取远程音源'); }
  const service = await server(t, incoming.root, {resolver: resolve, capabilities: catalog, maxConcurrent: 0});
  const manifest = await request(service, '/updates/manifest.json');
  const packageFile = await request(service, '/updates/' + incoming.packagePath);
  assert.equal(manifest.status, 200);
  assert.equal(manifest.headers['cache-control'], 'no-store');
  assert.equal(Number(manifest.headers['content-length']), incoming.manifest.length);
  assert.deepEqual(manifest.body, incoming.manifest);
  assert.equal(packageFile.status, 200);
  assert.equal(Number(packageFile.headers['content-length']), incoming.bytes.length);
  assert.deepEqual(packageFile.body, incoming.bytes);
  assert.equal(resolutions, 0);
  assert.equal(capabilities, 0);
});

test('only canonical GET update paths are exposed without URL normalization', async function paths(t) {
  const incoming = release(temporary(t), 1);
  const service = await server(t, incoming.root);
  for (const route of ['/updates/../manifest.json', '/updates/%2e%2e/manifest.json',
    '/updates/packages/%2e%2e/manifest.json', '/updates/packages%2fp000001.json',
    '/updates/packages\\p000001.json', '/updates/manifest.json?extra=1',
    '/updates/packages/p000001.json?extra=1', '/updates/previous-manifest.json',
    '/updates/packages/p000000.json', '/updates/packages/p0000001.json',
    '/updates/packages/p1.json', '/updates/packages/p1000000000.json']) {
    assert.equal((await request(service, route)).status, 404, route);
  }
  for (const method of ['POST', 'PUT', 'DELETE', 'HEAD']) {
    assert.equal((await request(service, '/updates/manifest.json', method)).status, 404, method);
  }
});

test('missing, empty and oversized update files are unavailable', async function limits(t) {
  const incoming = release(temporary(t), 1);
  const service = await server(t, incoming.root);
  assert.equal((await request(service, '/updates/packages/p000002.json')).status, 404);
  fs.writeFileSync(path.join(incoming.root, 'manifest.json'), Buffer.alloc(64 * 1024 + 1));
  assert.equal((await request(service, '/updates/manifest.json')).status, 503);
  fs.writeFileSync(path.join(incoming.root, incoming.packagePath), Buffer.alloc(maximumPackageBytes + 1));
  assert.equal((await request(service, '/updates/' + incoming.packagePath)).status, 503);
  fs.writeFileSync(path.join(incoming.root, 'manifest.json'), '');
  assert.equal((await request(service, '/updates/manifest.json')).status, 503);
  fs.writeFileSync(path.join(incoming.root, incoming.packagePath), '');
  assert.equal((await request(service, '/updates/' + incoming.packagePath)).status, 503);
});

test('linked update root and packages directory cannot expose external bytes', async function parentLinks(t) {
  const root = temporary(t);
  const incoming = release(root, 1);
  const rootLink = path.join(root, 'root-link');
  if (!link(t, incoming.root, rootLink, true)) return;
  const linkedRoot = await server(t, rootLink);
  assert.equal((await request(linkedRoot, '/updates/manifest.json')).status, 503);
  const other = path.join(root, 'other');
  fs.mkdirSync(other);
  if (!link(t, path.join(incoming.root, 'packages'), path.join(other, 'packages'), true)) return;
  const linkedPackages = await server(t, other);
  assert.equal((await request(linkedPackages, '/updates/' + incoming.packagePath)).status, 503);
});

test('linked manifest and package files cannot expose external bytes', async function finalLinks(t) {
  const root = temporary(t);
  const incoming = release(root, 1);
  const outside = path.join(root, 'outside.json');
  fs.writeFileSync(outside, 'private-external-value');
  fs.unlinkSync(path.join(incoming.root, 'manifest.json'));
  if (!link(t, outside, path.join(incoming.root, 'manifest.json'))) return;
  fs.unlinkSync(path.join(incoming.root, incoming.packagePath));
  if (!link(t, outside, path.join(incoming.root, incoming.packagePath))) return;
  const service = await server(t, incoming.root);
  for (const route of ['/updates/manifest.json', '/updates/' + incoming.packagePath]) {
    const result = await request(service, route);
    assert.equal(result.status, 503);
    assert.equal(result.body.includes('private-external-value'), false);
  }
});

test('front proxy transfers a full 1 MiB package and preserves update restrictions', async function frontLimits(t) {
  const incoming = release(temporary(t), 1);
  const bytes = Buffer.alloc(maximumPackageBytes, 'x');
  fs.writeFileSync(path.join(incoming.root, incoming.packagePath), bytes);
  const service = await server(t, incoming.root);
  const upstream = 'http://127.0.0.1:' + service.address().port + '/';
  const proxy = await listen(t, createFrontProxy({musicUpstream: upstream, siteUpstream: upstream, testOnlyHttp: true}));
  const result = await request(proxy, '/music-player-api/updates/' + incoming.packagePath);
  assert.equal(result.status, 200);
  assert.deepEqual(result.body, bytes);
  assert.equal(Number(result.headers['content-length']), maximumPackageBytes);
  const manifest = await request(proxy, '/music-player-api/updates/manifest.json');
  assert.equal(manifest.headers['cache-control'], 'no-store');
  assert.deepEqual(manifest.body, incoming.manifest);
  for (const route of ['/updates/manifest.json?query=1', '/updates/packages/%2e%2e/manifest.json', '/updates/packages/p0000001.json']) {
    assert.equal((await request(proxy, '/music-player-api' + route)).status, 404);
  }
});

test('front proxy rejects package and manifest responses exceeding their budgets', async function frontBudgets(t) {
  const upstream = await listen(t, http.createServer(function oversized(request, response) {
    const length = request.url === '/updates/manifest.json' ? 64 * 1024 + 1 : maximumPackageBytes + 1;
    response.end(Buffer.alloc(length, 'x'));
  }));
  const base = 'http://127.0.0.1:' + upstream.address().port + '/';
  const proxy = await listen(t, createFrontProxy({musicUpstream: base, siteUpstream: base, testOnlyHttp: true}));
  for (const route of ['/updates/manifest.json', '/updates/packages/p000001.json']) {
    const response = await request(proxy, '/music-player-api' + route);
    assert.equal(response.status, 502);
    assert.equal(JSON.parse(response.body).code, 'RESPONSE_TOO_LARGE');
  }
});

test('client disconnect closes the package stream and keeps the service usable', {timeout: 2000}, async function disconnect(t) {
  const incoming = release(temporary(t), 1);
  const packageFile = path.join(incoming.root, incoming.packagePath);
  fs.writeFileSync(packageFile, Buffer.alloc(maximumPackageBytes));
  const original = fs.promises.open;
  let stream;
  let closed;
  const released = new Promise(function complete(resolve) { closed = resolve; });
  fs.promises.open = async function track(file, flags) {
    const handle = await original(file, flags);
    if (file !== packageFile) return handle;
    const create = handle.createReadStream.bind(handle);
    handle.createReadStream = function trackStream(options) {
      stream = create(options);
      stream.once('close', closed);
      return stream;
    };
    return handle;
  };
  t.after(function restore() { fs.promises.open = original; });
  const service = await server(t, incoming.root);
  await new Promise(function abortDownload(resolve, reject) {
    const outgoing = http.get({hostname: '127.0.0.1', port: service.address().port,
      path: '/updates/' + incoming.packagePath, agent: false}, function received(response) {
      response.once('data', function interrupt() { response.destroy(); outgoing.destroy(); resolve(); });
    });
    outgoing.once('error', reject);
  });
  await released;
  assert.equal(stream.destroyed, true);
  assert.equal((await request(service, '/health')).status, 200);
});

test('publisher verifies raw signatures and keeps only current plus previous versions', function retention(t) {
  const root = temporary(t);
  const destination = path.join(root, 'published');
  for (let version = 1; version <= 3; version++) {
    const incoming = release(root, version);
    assert.equal(verifyPackageManifest(incoming.manifest, publicKeyBase64).packageVersion, version);
    assert.equal(inspectPlaybackPackage({stagingRoot: incoming.root, publicKeyBase64}).bytes, incoming.bytes.length);
    const result = install(incoming, destination);
    assert.equal(result.packageVersion, version);
    assert.equal(result.previousVersion, version === 1 ? null : version - 1);
    assert.deepEqual(current(destination), incoming.manifest);
  }
  assert.deepEqual(fs.readdirSync(path.join(destination, 'packages')).sort(), ['p000002.json', 'p000003.json']);
  assert.equal(verifyPackageManifest(fs.readFileSync(path.join(destination, 'previous-manifest.json')), publicKeyBase64).packageVersion, 2);
});

test('duplicate, downgrade and orphan versions cannot replace the current release', function monotonic(t) {
  const root = temporary(t);
  const destination = path.join(root, 'published');
  const initial = release(root, 2);
  install(initial, destination);
  for (const version of [1, 2]) {
    assert.throws(function repeat() { install(release(root, version), destination); }, /版本必须大于/);
    unchanged(destination, initial.manifest);
  }
  fs.writeFileSync(path.join(destination, 'packages', 'p000004.json'), '{}');
  assert.throws(function orphanVersion() { install(release(root, 3), destination); }, /版本必须大于/);
  unchanged(destination, initial.manifest);
});

test('untrusted signature, digest and manifest limits preserve the valid release', function invalidManifest(t) {
  const root = temporary(t);
  const destination = path.join(root, 'published');
  const initial = release(root, 1);
  install(initial, destination);
  const otherKey = crypto.generateKeyPairSync('ed25519');
  const cases = [{signer: otherKey.privateKey}, {payload: {sha256: '0'.repeat(64)}},
    {payload: {bytes: maximumPackageBytes + 1}}, {payload: {packagePath: 'packages/../manifest.json'}},
    {payload: {packageVersion: 1000000000}}, {payload: {minimumBridgeVersion: 2}}];
  for (const value of cases) {
    const incoming = release(root, 2, value);
    assert.throws(function invalid() { install(incoming, destination); });
    unchanged(destination, initial.manifest);
  }
  const large = release(root, 2);
  fs.writeFileSync(path.join(large.root, 'manifest.json'), Buffer.alloc(64 * 1024 + 1));
  assert.throws(function oversized() { install(large, destination); }, /大小无效/);
  unchanged(destination, initial.manifest);
});

test('invalid code, origins and dynamic capability definitions cannot be published', function invalidBundle(t) {
  const root = temporary(t);
  const destination = path.join(root, 'published');
  const initial = release(root, 1);
  install(initial, destination);
  const invalid = [null, {...bundle(2), script: ''}, {...bundle(2), allowedOrigins: ['file:///etc/passwd']},
    {...bundle(2), allowedOrigins: ['https://user:pass@audio.example']},
    {...bundle(2), capabilities: {...bundle(2).capabilities, sources: Array(33).fill(bundle(2).capabilities.sources[0])}},
    {...bundle(2), capabilities: {protocolVersion: 1, revision: 'test', sources: [{id: 'automatic', name: 'bad', platforms: []}]}}];
  for (const value of invalid) {
    const incoming = release(root, 2, {bundle: value === null ? {packageFormat: 2} : value});
    assert.throws(function invalid() { install(incoming, destination); });
    unchanged(destination, initial.manifest);
  }
  const tooManyFields = bundle(2);
  tooManyFields.capabilities.sources[0].credentials = Array(17).fill({key: 'test', label: '字段', requiredPlatforms: []});
  assert.throws(function fields() { install(release(root, 2, {bundle: tooManyFields}), destination); });
  unchanged(destination, initial.manifest);
});

test('unexpected directory entries and held publish locks preserve the valid release', function occupied(t) {
  const root = temporary(t);
  const destination = path.join(root, 'published');
  const initial = release(root, 1);
  const incoming = release(root, 2);
  install(initial, destination);
  const extra = path.join(destination, 'packages', 'unexpected.txt');
  fs.writeFileSync(extra, 'unrelated-file');
  assert.throws(function unexpected() { install(incoming, destination); }, /名称异常/);
  assert.equal(fs.readFileSync(extra, 'utf8'), 'unrelated-file');
  unchanged(destination, initial.manifest);
  fs.unlinkSync(extra);
  const lock = path.join(destination, '.publish.lock');
  fs.mkdirSync(lock);
  assert.throws(function busy() { install(incoming, destination); }, /发布锁/);
  assert.deepEqual(current(destination), initial.manifest);
  assert.equal(fs.existsSync(lock), true);
  fs.rmdirSync(lock);
});

test('linked staging and publication directories are rejected', function installerDirectoryLinks(t) {
  const root = temporary(t);
  const initial = release(root, 1);
  const destination = path.join(root, 'published');
  install(initial, destination);
  const incoming = release(root, 2);
  const stagingLink = path.join(root, 'staging-link');
  if (!link(t, incoming.root, stagingLink, true)) return;
  assert.throws(function stageLink() { install({...incoming, root: stagingLink}, destination); }, /符号链接/);
  const destinationLink = path.join(root, 'published-link');
  if (!link(t, destination, destinationLink, true)) return;
  assert.throws(function publishLink() { install(incoming, destinationLink); }, /符号链接/);
  const packageDirectory = path.join(incoming.root, 'packages');
  fs.renameSync(packageDirectory, path.join(incoming.root, 'original-packages'));
  if (!link(t, path.join(incoming.root, 'original-packages'), packageDirectory, true)) return;
  assert.throws(function packagesLink() { install(incoming, destination); }, /符号链接/);
  unchanged(destination, initial.manifest);
});

test('linked publication files are retained and never replaced', function installerFileLinks(t) {
  const root = temporary(t);
  const destination = path.join(root, 'published');
  const initial = release(root, 1);
  install(initial, destination);
  const external = path.join(root, 'external.json');
  fs.writeFileSync(external, 'unrelated-secret');
  const linked = path.join(destination, 'packages', 'p000002.json');
  if (!link(t, external, linked)) return;
  assert.throws(function invalidLink() { install(release(root, 3), destination); }, /符号链接/);
  assert.equal(fs.lstatSync(linked).isSymbolicLink(), true);
  assert.equal(fs.readFileSync(external, 'utf8'), 'unrelated-secret');
  unchanged(destination, initial.manifest);
});

test('manifest switch failure restores previous marker and removes incomplete artifacts', function rollback(t) {
  const root = temporary(t);
  const destination = path.join(root, 'published');
  install(release(root, 1), destination);
  const second = release(root, 2);
  install(second, destination);
  const previous = fs.readFileSync(path.join(destination, 'previous-manifest.json'));
  const original = fs.renameSync;
  fs.renameSync = function failFinal(source, target) {
    if (target === path.join(destination, 'manifest.json')) throw new Error('模拟清单原子切换失败');
    return original(source, target);
  };
  try { assert.throws(function failing() { install(release(root, 3), destination); }, /模拟清单/); }
  finally { fs.renameSync = original; }
  unchanged(destination, second.manifest);
  assert.deepEqual(fs.readFileSync(path.join(destination, 'previous-manifest.json')), previous);
  assert.deepEqual(fs.readdirSync(path.join(destination, 'packages')).sort(), ['p000001.json', 'p000002.json']);
});

test('initial publication failure leaves no current or previous marker', function firstRollback(t) {
  const root = temporary(t);
  const incoming = release(root, 1);
  const destination = path.join(root, 'published');
  const original = fs.renameSync;
  fs.renameSync = function failFinal(source, target) {
    if (target === path.join(destination, 'manifest.json')) throw new Error('模拟首次切换失败');
    return original(source, target);
  };
  try { assert.throws(function failing() { install(incoming, destination); }, /模拟首次/); }
  finally { fs.renameSync = original; }
  assert.deepEqual(fs.readdirSync(destination), ['packages']);
  assert.deepEqual(fs.readdirSync(path.join(destination, 'packages')), []);
});

test('write and fsync failures clean temporary files and preserve the valid package', function writeRollback(t) {
  const root = temporary(t);
  const initial = release(root, 1);
  const incoming = release(root, 2);
  const destination = path.join(root, 'published');
  install(initial, destination);
  for (const operation of ['writeFileSync', 'fsyncSync']) {
    const original = fs[operation];
    fs[operation] = function failWrite() { throw new Error('模拟更新写盘失败'); };
    try { assert.throws(function failed() { install(incoming, destination); }, /模拟更新写盘失败/); }
    finally { fs[operation] = original; }
    unchanged(destination, initial.manifest);
    assert.deepEqual(fs.readdirSync(path.join(destination, 'packages')), ['p000001.json']);
  }
});

test('manifest is the last rename and always references an already installed package', function switchOrder(t) {
  const root = temporary(t);
  const destination = path.join(root, 'published');
  install(release(root, 1), destination);
  const incoming = release(root, 2);
  const targets = [];
  const original = fs.renameSync;
  fs.renameSync = function track(source, target) {
    targets.push(target);
    if (target === path.join(destination, 'manifest.json')) {
      assert.deepEqual(fs.readFileSync(path.join(destination, incoming.packagePath)), incoming.bytes);
    }
    return original(source, target);
  };
  try { install(incoming, destination); }
  finally { fs.renameSync = original; }
  assert.deepEqual(targets, [path.join(destination, incoming.packagePath),
    path.join(destination, 'previous-manifest.json'), path.join(destination, 'manifest.json')]);
});

test('file growth during inspection is rejected without reading past the checked size', function growingFile(t) {
  const incoming = release(temporary(t), 1);
  const original = fs.readSync;
  let enlarged = false;
  let largestRequest = 0;
  fs.readSync = function append(descriptor, bytes, offset, length, position) {
    largestRequest = Math.max(largestRequest, length);
    if (!enlarged) {
      enlarged = true;
      fs.appendFileSync(path.join(incoming.root, 'manifest.json'), Buffer.alloc(128 * 1024));
    }
    return original(descriptor, bytes, offset, length, position);
  };
  try {
    assert.throws(function inspect() { inspectPlaybackPackage({stagingRoot: incoming.root, publicKeyBase64}); }, /大小发生变化/);
  } finally { fs.readSync = original; }
  assert.equal(largestRequest, incoming.manifest.length);
});

test('builder accepts maximum version and refuses versions outside the published protocol', function builderVersions(t) {
  const root = temporary(t);
  const privateKeyFile = path.join(root, 'test-publisher.pem');
  fs.writeFileSync(privateKeyFile, identity.privateKey.export({type: 'pkcs8', format: 'pem'}));
  const outputDirectory = path.join(root, 'build');
  for (const version of [0, -1, 1.5, 1000000000]) {
    assert.throws(function invalidVersion() { buildPlaybackPackage({outputDirectory, version, privateKeyFile}); }, /正整数/);
  }
  const result = buildPlaybackPackage({outputDirectory, version: 999999999, privateKeyFile});
  assert.equal(result.packagePath, 'packages/p999999999.json');
  assert.equal(inspectPlaybackPackage({stagingRoot: outputDirectory, publicKeyBase64}).packageVersion, 999999999);
});
