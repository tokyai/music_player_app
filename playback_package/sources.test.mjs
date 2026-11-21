import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import vm from 'node:vm';
import {buildPlaybackPackage} from '../tools/build_playback_package.mjs';

const originalScript = fs.readFileSync(new URL('./sources.js', import.meta.url), 'utf8');
const song = {platform: '163', id: '347230', name: '海阔天空', artist: 'BEYOND', album: '乐与怒', duration: 326, quality: 'exhigh'};
const playable = {url: 'https://cdn.example.com/song.mp3', format: 'mp3'};

function reply(data, status = 200) { return {status, bodyText: JSON.stringify(data)}; }
function plain(value) { return JSON.parse(JSON.stringify(value)); }
function unavailable() { return reply({code: 404}); }
function never() { return new Promise(function wait() {}); }

class HostFixture {
  constructor(respond = unavailable, {script = originalScript, deadlineDelayMs, ignoreRequestCancellation = false} = {}) {
    this.respond = respond;
    this.calls = [];
    this.pending = new Set();
    this.clock = 1800000000000;
    this.nonce = 0;
    this.deadlineDelayMs = deadlineDelayMs;
    this.ignoreRequestCancellation = ignoreRequestCancellation;
    const host = {sha256: this.sha256.bind(this), hmacSha256: this.hmacSha256.bind(this),
      randomHex: this.randomHex.bind(this), now: this.now.bind(this), request: this.request.bind(this),
      delay: this.delay.bind(this), cancel: this.cancel.bind(this)};
    this.context = vm.createContext({KuzaiHost: host});
    vm.runInContext(script, this.context, {timeout: 1000, filename: 'sources.js'});
    this.api = this.context.KuzaiSources;
  }

  sha256(text) { return crypto.createHash('sha256').update(text).digest('hex'); }
  hmacSha256(key, text) { return crypto.createHmac('sha256', key).update(text).digest('hex'); }
  randomHex(bytes) { this.nonce++; return String(this.nonce).padStart(bytes * 2, '0'); }
  now() { return this.clock; }

  request(scopeId, parameters) {
    const fixture = this;
    const record = {scopeId, type: 'request'};
    this.calls.push({scopeId, ...parameters});
    return new Promise(function start(resolve, reject) {
      record.reject = reject;
      fixture.pending.add(record);
      function success(value) {
        if (!fixture.pending.delete(record)) return;
        resolve(value);
      }
      function failure(error) {
        if (!fixture.pending.delete(record)) return;
        reject(error);
      }
      Promise.resolve().then(function send() { return fixture.respond(parameters, scopeId); }).then(success, failure);
    });
  }

  delay(scopeId, milliseconds) {
    const fixture = this;
    const record = {scopeId, type: 'timer'};
    return new Promise(function start(resolve, reject) {
      record.reject = reject;
      fixture.pending.add(record);
      function elapsed() {
        if (!fixture.pending.delete(record)) return;
        resolve();
      }
      record.timer = setTimeout(elapsed, fixture.deadlineDelayMs === undefined ? milliseconds : fixture.deadlineDelayMs);
    });
  }

  cancel(scopeId) {
    for (const record of Array.from(this.pending)) {
      if (record.scopeId !== scopeId || (record.type === 'request' && this.ignoreRequestCancellation)) continue;
      this.pending.delete(record);
      clearTimeout(record.timer);
      const error = new Error('已取消');
      error.code = 'RESOLVE_CANCELLED';
      record.reject(error);
    }
  }

  close() {
    this.api.dispose();
    this.ignoreRequestCancellation = false;
    for (const record of Array.from(this.pending)) this.cancel(record.scopeId);
  }
}

function fixture(t, respond, options) {
  const value = new HostFixture(respond, options);
  t.after(function dispose() { value.close(); });
  return value;
}

test('built-in package exposes five sources without contacting a server', function builtIn(t) {
  const value = fixture(t);
  const capabilities = plain(value.api.getCapabilities());
  assert.equal(capabilities.protocolVersion, 1);
  assert.equal(capabilities.sources.length, 5);
  assert.equal(value.calls.length, 0);
  assert.equal(value.pending.size, 0);
  assert.ok(Object.isFrozen(value.api.allowedOrigins));
});

test('Qing signs and sends the exact body text using only the native Host contract', async function qingSignature(t) {
  function respond() { return reply({code: 0, data: playable}, 201); }
  const value = fixture(t, respond);
  const result = await value.api.resolve({...song, platform: 'qq', source: 'qing_music', quality: 'hires'}, 'qing1');
  const sent = value.calls[0];
  assert.equal(result.providerId, 'qing_music');
  assert.deepEqual(JSON.parse(sent.bodyText), {source: 'tx', rid: song.id, level: 'lossless'});
  const signature = ['qingmusic-android', sent.headers['X-Qing-Ts'], sent.headers['X-Qing-Nonce'],
    'POST', '/v1/music/resolve-url', value.sha256(sent.bodyText)].join('\n');
  assert.equal(sent.headers['X-Qing-Sign'], value.hmacSha256('qm-gw-7c1f4e9a2b8d5360e1a7c4f9b2d8036c', signature));
  assert.equal(sent.method, 'POST');
  assert.equal(sent.maxBytes, 512 * 1024);
  assert.equal(value.pending.size, 0);
});

test('HYW public parameters update with the package and personal keys remain local', async function hywPublicConfig(t) {
  function respond() { return reply({code: 200, data: playable}); }
  const updated = originalScript.replace("const publicHywCardKey = '6C1F-53W0-GRKI-EVFG';", "const publicHywCardKey = 'updated-public-card';");
  const value = fixture(t, respond, {script: updated});
  await value.api.resolve({...song, source: 'hyw', quality: 'hires'}, 'hyw1');
  assert.equal(new URL(value.calls[0].url).searchParams.get('key'), 'updated-public-card');
  assert.equal(new URL(value.calls[0].url).searchParams.get('quality'), 'flac24bit');
  await value.api.resolve({...song, source: 'hyw', credentials: {hyw: {hywCardKey: '个人卡密'}}}, 'hyw2');
  assert.equal(new URL(value.calls[1].url).searchParams.get('key'), '个人卡密');
  assert.equal(Object.keys(value.calls[1].headers).some(isCardHeader), false);
  function isCardHeader(key) { return key.toLowerCase().includes('card-key'); }
});

test('package credentials are scoped and missing authorization is reported without HTTP', async function credentials(t) {
  const value = fixture(t);
  await assert.rejects(value.api.resolve({...song, source: 'chksz'}, 'missing1'), {code: 'CREDENTIAL_REQUIRED'});
  await assert.rejects(value.api.resolve({...song, platform: 'qq', source: 'xinghai', quality: '320k'}, 'missing2'), {code: 'CREDENTIAL_REQUIRED'});
  await assert.rejects(value.api.resolve({...song, source: 'hyw', credentials: {hyw: {hywCardKey: 'bad\nkey'}}}, 'invalid'), {code: 'INVALID_CREDENTIALS'});
  await assert.rejects(value.api.resolve({...song, source: 'constructor'}, 'prototype'), {code: 'SOURCE_UNAVAILABLE'});
  assert.equal(value.calls.length, 0);
});

test('Xinghai reuses bounded tokens and refreshes only explicit token errors', async function tokenRefresh(t) {
  let tokenCalls = 0;
  let musicCalls = 0;
  function respond(parameters) {
    if (parameters.url.includes('/token.php')) {
      tokenCalls++;
      assert.equal(parameters.maxBytes, 64 * 1024);
      return reply({code: 200, data: {token: 'xh3.token_' + tokenCalls}});
    }
    musicCalls++;
    if (musicCalls === 1) return reply({code: 401, auth: {tk_mismatch: true}});
    return reply({code: 200, data: playable});
  }
  const value = fixture(t, respond);
  await value.api.resolve({...song, source: 'xinghai'}, 'token1');
  await value.api.resolve({...song, source: 'xinghai'}, 'token2');
  assert.equal(tokenCalls, 2);
  assert.equal(musicCalls, 3);
  function authorization(parameters) {
    if (parameters.url.includes('/token.php')) { tokenCalls++; return reply({code: 200, data: {token: 'xh3.valid'}}); }
    return reply({code: 401, message: '授权卡密失效'});
  }
  value.respond = authorization;
  await assert.rejects(value.api.resolve({...song, platform: 'qq', source: 'xinghai', quality: '320k', credentials: {xinghai: {xinghaiLicenseKey: 'personal'}}}, 'license1'), {code: 'XINGHAI_AUTH_REQUIRED'});
  assert.equal(tokenCalls, 3);
  assert.equal(value.pending.size, 0);
});

test('Xinghai token cache retains at most sixteen identities and rejects invalid tickets', async function tokenBound(t) {
  let tokenCalls = 0;
  function respond(parameters) {
    if (parameters.url.includes('/token.php')) { tokenCalls++; return reply({code: 200, data: {token: 'xh3.valid_' + tokenCalls}}); }
    return reply({code: 200, data: playable});
  }
  const value = fixture(t, respond);
  for (let index = 0; index < 17; index++) {
    await value.api.resolve({...song, source: 'xinghai', credentials: {xinghai: {xinghaiLicenseKey: 'identity_' + index}}}, 'identity_' + index);
  }
  await value.api.resolve({...song, source: 'xinghai', credentials: {xinghai: {xinghaiLicenseKey: 'identity_0'}}}, 'again');
  assert.equal(tokenCalls, 18);
  function invalidTicket() { tokenCalls++; return reply({code: 200, data: {token: 'xh3.should_not_cache'}}, 500); }
  value.respond = invalidTicket;
  const input = {...song, source: 'xinghai', credentials: {xinghai: {xinghaiLicenseKey: 'bad_ticket'}}};
  await assert.rejects(value.api.resolve(input, 'invalid1'), {code: 'TOKEN_INVALID'});
  await assert.rejects(value.api.resolve(input, 'invalid2'), {code: 'TOKEN_INVALID'});
  assert.equal(tokenCalls, 20);
});

test('GD matches the same recording and deduplicates effective high-quality bitrates', async function gdMatch(t) {
  function respond(parameters) {
    const url = new URL(parameters.url);
    if (url.searchParams.get('types') === 'search') {
      return reply([{id: 10, source: 'netease', name: '海阔天空', artist: ['翻唱歌手']},
        {id: 347230, source: 'netease', name: '海阔天空', artist: ['BEYOND'], duration: 326000}]);
    }
    if (url.searchParams.get('br') === '999') return reply({url: ''});
    return reply(playable);
  }
  const value = fixture(t, respond);
  const result = await value.api.resolve({...song, platform: 'qq', source: 'gd_studio', quality: 'hires'}, 'gd1');
  assert.equal(result.providerId, 'gd_studio');
  const bitrates = [];
  for (const call of value.calls) {
    const url = new URL(call.url);
    if (url.searchParams.get('types') === 'url') {
      assert.equal(url.searchParams.get('id'), '347230');
      bitrates.push(url.searchParams.get('br'));
    }
  }
  assert.deepEqual(bitrates, ['999', '740']);
});

test('automatic fallback avoids duplicate Qing levels and never upgrades standard', async function qualityFallback(t) {
  const value = fixture(t);
  const disabledSources = ['xinghai', 'hyw', 'gd_studio', 'chksz'];
  await assert.rejects(value.api.resolve({...song, platform: 'qq', source: 'automatic', quality: 'hires', disabledSources}, 'quality1'), {code: 'SOURCES_UNAVAILABLE'});
  function level(parameters) { return JSON.parse(parameters.bodyText).level; }
  assert.deepEqual(value.calls.map(level), ['lossless', 'exhigh', 'standard']);
  value.calls.length = 0;
  await assert.rejects(value.api.resolve({...song, quality: 'standard', disabledSources}, 'quality2'), {code: 'SOURCES_UNAVAILABLE'});
  assert.deepEqual(value.calls.map(level), ['standard']);
});

test('Qing authentication failures stop quality retries', async function qingGate(t) {
  function respond() { return reply({code: 'APP_SIGN_INVALID'}, 401); }
  const value = fixture(t, respond);
  await assert.rejects(value.api.resolve({...song, quality: 'jymaster', disabledSources: ['xinghai', 'hyw', 'gd_studio', 'chksz']}, 'auth1'), {code: 'SOURCES_UNAVAILABLE'});
  assert.equal(value.calls.length, 1);
});

test('cancellation and package deadline release all requests and timers', async function cancel(t) {
  const value = fixture(t, never);
  const resolving = value.api.resolve({...song, source: 'qing_music'}, 'cancel1');
  await Promise.resolve();
  value.api.cancel('cancel1');
  await assert.rejects(resolving, {code: 'RESOLVE_CANCELLED'});
  assert.equal(value.pending.size, 0);
  const deadline = fixture(t, never, {deadlineDelayMs: 15});
  await assert.rejects(deadline.api.resolve({...song, source: 'qing_music'}, 'timeout1'), {code: 'RESOLVE_TIMEOUT'});
  assert.equal(deadline.pending.size, 0);
});

test('late cancelled ticket cannot populate the new-operation token cache', async function lateToken(t) {
  let tokenCalls = 0;
  let complete;
  function respond(parameters) {
    if (parameters.url.includes('/token.php')) {
      tokenCalls++;
      if (tokenCalls === 1) return new Promise(function hold(resolve) { complete = resolve; });
      return reply({code: 200, data: {token: 'xh3.new'}});
    }
    return reply({code: 200, data: playable});
  }
  const value = fixture(t, respond, {ignoreRequestCancellation: true});
  const resolving = value.api.resolve({...song, source: 'xinghai'}, 'old');
  await Promise.resolve();
  value.api.cancel('old');
  complete(reply({code: 200, data: {token: 'xh3.late'}}));
  await assert.rejects(resolving, {code: 'RESOLVE_CANCELLED'});
  await value.api.resolve({...song, source: 'xinghai'}, 'new');
  assert.equal(tokenCalls, 2);
});

test('package limits concurrent operations and consumes every cancelled result', async function concurrency(t) {
  const value = fixture(t, never);
  const pending = [];
  for (let index = 0; index < 4; index++) pending.push(value.api.resolve({...song, source: 'qing_music'}, 'op_' + index));
  await assert.rejects(value.api.resolve({...song, source: 'qing_music'}, 'op_5'), {code: 'RESOLVE_BUSY'});
  await Promise.resolve();
  value.api.dispose();
  const outcomes = await Promise.allSettled(pending);
  for (const outcome of outcomes) assert.equal(outcome.reason.code, 'RESOLVE_CANCELLED');
  assert.equal(value.pending.size, 0);
  await assert.rejects(value.api.resolve({...song, source: 'qing_music'}, 'after_dispose'), {code: 'RESOLVE_CANCELLED'});
});

test('new sources never increase each race beyond four native HTTP requests', async function raceLimit(t) {
  const definitions = [];
  const handlers = [];
  for (let index = 0; index < 8; index++) {
    definitions.push({id: 'future_' + index, name: '新增源', description: '测试并发', platforms: ['163'], group: 0, credentials: []});
    handlers.push('future_' + index + ':futureRequest');
  }
  const updated = originalScript.replace('const sources = [', 'const sources = ' + JSON.stringify(definitions).slice(0, -1) + ',')
    .replace('const handlers = {', 'async function futureRequest(song, context) { return requestJson("https://api.chksz.com/future", context); }\n  const handlers = {' + handlers.join(',') + ',');
  let active = 0;
  let maximum = 0;
  async function respond() {
    active++;
    maximum = Math.max(maximum, active);
    function wait(resolve) { setTimeout(resolve, 5); }
    await new Promise(wait);
    active--;
    return reply({code: 404});
  }
  const value = fixture(t, respond, {script: updated});
  await assert.rejects(value.api.resolve({...song, quality: 'jymaster', disabledSources: ['qing_music', 'xinghai', 'hyw', 'gd_studio', 'chksz']}, 'race1'), {code: 'SOURCES_UNAVAILABLE'});
  assert.equal(maximum, 4);
  assert.equal(value.calls.length, 32);
  assert.equal(value.pending.size, 0);
});

test('failed native timer initialization does not retain an operation', async function failedHost(t) {
  function respond() { return reply({code: 0, data: playable}); }
  const value = fixture(t, respond);
  function unavailableTimer() { throw new Error('native timer unavailable'); }
  value.context.KuzaiHost.delay = unavailableTimer;
  for (let index = 0; index < 5; index++) {
    await assert.rejects(value.api.resolve({...song, source: 'qing_music'}, 'failed_' + index), /native timer unavailable/);
  }
  value.context.KuzaiHost.delay = value.delay.bind(value);
  const result = await value.api.resolve({...song, source: 'qing_music'}, 'recovered');
  assert.equal(result.providerId, 'qing_music');
  assert.equal(value.pending.size, 0);
});

test('new source definitions and handlers are discovered without changing Host', async function newSource(t) {
  // 模拟发布者仅在更新包中添加定义和处理函数，native 桥接保持原样。
  const modified = originalScript.replace('const sources = [', "const sources = [{id:'future_source',name:'新音源',description:'新增解析',platforms,group:0,credentials:[]},")
    .replace('const handlers = {', "async function futureSource() { return {url:'https://cdn.example.com/new.mp3',format:'mp3'}; }\n  const handlers = {future_source:futureSource,");
  const value = fixture(t, unavailable, {script: modified});
  assert.equal(value.api.getCapabilities().sources.length, 6);
  const result = await value.api.resolve({...song, source: 'future_source'}, 'future1');
  assert.equal(result.providerId, 'future_source');
  assert.equal(result.providerName, '新音源');
  assert.equal(value.calls.length, 0);
});

test('invalid metadata audio formats URLs and headers are refused', async function invalidData(t) {
  const value = fixture(t);
  await assert.rejects(value.api.resolve({...song, platform: 'toString'}, 'invalid1'), {code: 'INVALID_SONG'});
  await assert.rejects(value.api.resolve({...song, quality: 'unknown'}, 'invalid2'), {code: 'INVALID_QUALITY'});
  await assert.rejects(value.api.resolve({...song, source: ''}, 'invalid_source'), {code: 'INVALID_SOURCE'});
  await assert.rejects(value.api.resolve({...song, quality: 0}, 'invalid_quality'), {code: 'INVALID_QUALITY'});
  await assert.rejects(value.api.resolve({...song, excludedSources: Array(33).fill('qing_music')}, 'invalid3'), {code: 'INVALID_SOURCE'});
  for (const invalid of [{url: 'file:///private/song.mp3'}, {url: 'https://user:pass@cdn.example.com/song.mp3'},
    {url: 'https://cdn.example.com/song.mp3', format: 'cenc'},
    {url: 'https://cdn.example.com/song.mp3', headers: {'X-Test': 'bad\r\nInjected: true'}},
    {url: 'https://cdn.example.com/song.mp3', headers: {Host: 'localhost'}}]) {
    function respond() { return reply({code: 0, data: invalid}); }
    value.respond = respond;
    await assert.rejects(value.api.resolve({...song, source: 'qing_music'}, 'audio_invalid'));
  }
  assert.equal(value.pending.size, 0);
});

test('optional null metadata behaves like omitted fields in the existing protocol', async function optionalMetadata(t) {
  function respond() { return reply({code: 0, data: playable}); }
  const value = fixture(t, respond);
  const result = await value.api.resolve({...song, source: 'qing_music', name: null,
    artist: null, album: null, albumId: null, duration: null, quality: null}, 'optional1');
  assert.equal(result.providerId, 'qing_music');
  assert.equal(JSON.parse(value.calls[0].bodyText).level, 'exhigh');
  assert.equal(value.pending.size, 0);
});

test('a bridge response larger than its requested limit is refused before JSON decoding', async function oversizedHost(t) {
  function respond() { return {status: 200, bodyText: 'x'.repeat(512 * 1024 + 1)}; }
  const value = fixture(t, respond);
  await assert.rejects(value.api.resolve({...song, source: 'qing_music'}, 'large1'), {code: 'RESPONSE_TOO_LARGE'});
  assert.equal(value.pending.size, 0);
});

test('builder signs raw manifest bytes and emits no private or server credentials', function build(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'kuzai-package-test-'));
  function cleanup() {
    const resolved = fs.realpathSync(directory);
    const tempRoot = fs.realpathSync(os.tmpdir());
    assert.ok(resolved.startsWith(tempRoot + path.sep) && path.basename(resolved).startsWith('kuzai-package-test-'));
    fs.rmSync(resolved, {recursive: true, force: true});
  }
  t.after(cleanup);
  const pair = crypto.generateKeyPairSync('ed25519');
  const privateFile = path.join(directory, 'fixture-private.pem');
  fs.writeFileSync(privateFile, pair.privateKey.export({type: 'pkcs8', format: 'pem'}));
  const outputDirectory = path.join(directory, 'output');
  const result = buildPlaybackPackage({outputDirectory, version: 17, privateKeyFile: privateFile});
  const manifest = JSON.parse(fs.readFileSync(result.manifestPath));
  const payload = Buffer.from(manifest.payloadBase64, 'base64');
  assert.equal(crypto.verify(null, payload, pair.publicKey, Buffer.from(manifest.signatureBase64, 'base64')), true);
  const parsed = JSON.parse(payload);
  const bytes = fs.readFileSync(result.bundlePath);
  assert.equal(parsed.packagePath, 'packages/p000017.json');
  assert.equal(parsed.bytes, bytes.length);
  assert.equal(parsed.sha256, crypto.createHash('sha256').update(bytes).digest('hex'));
  const bundle = JSON.parse(bytes);
  assert.equal(bundle.capabilities.revision, 'p000017');
  assert.equal(bundle.packageVersion, 17);
  assert.equal(bundle.capabilities.sources.length, 5);
  assert.equal(bytes.includes(Buffer.from('PRIVATE KEY')), false);
  assert.equal(bytes.includes(Buffer.from(privateFile)), false);
  assert.ok(bytes.length < 1024 * 1024);
  assert.throws(function missingKey() { buildPlaybackPackage({outputDirectory, version: 18, privateKeyFile: path.join(directory, 'missing.pem')}); }, /未找到已有发布私钥/);
  assert.throws(function badVersion() { buildPlaybackPackage({outputDirectory, version: 0, privateKeyFile: privateFile}); }, /正整数/);
});
