import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import http from 'node:http';
import {spawnSync} from 'node:child_process';
import {once} from 'node:events';
import test from 'node:test';
import {createPlaybackResolver, getCapabilities, sources} from './sources.mjs';
import {fetchJson, resolved, SourceError} from './network.mjs';
import {createPlaybackServer} from './server.mjs';

const song = {platform: '163', id: 'song-1', name: '海阔天空', artist: 'BEYOND',
  album: '乐与怒', duration: 326, quality: 'exhigh'};
const playable = {url: 'https://audio.example/song.mp3', format: 'mp3', playbackHeaders: {}};

function definition(id, overrides = {}) {
  return {id, name: id, description: '测试音源', platforms: ['163', 'qq', 'kugou'], group: 0, credentials: [], ...overrides};
}

async function fixture(t, options = {}) {
  const server = createPlaybackServer(options);
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(async function cleanupServer() {
    server.cancelPlaybackRequests();
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  });
  return `http://127.0.0.1:${server.address().port}`;
}

function waitForCancellation(_song, context) {
  return new Promise(function awaitAbort(_resolve, reject) {
    const cancel = () => reject(new SourceError('RESOLVE_CANCELLED', '已取消'));
    context.signal.addEventListener('abort', cancel, {once: true});
    if (context.signal.aborted) cancel();
  });
}

test('new source definition and handler are discovered without a client change', async function newSource() {
  const definitions = [...sources, definition('future_source')];
  const resolve = createPlaybackResolver({definitions, handlerMap: {future_source: async () => playable}});
  const result = await resolve(song);
  assert.equal(result.providerId, 'future_source');
  assert.equal(result.protocolVersion, 1);
  assert.equal(result.quality, 'exhigh');
  assert.ok(getCapabilities(definitions).sources.some(item => item.id === 'future_source'));
  assert.equal(JSON.stringify(getCapabilities(definitions)).includes('client-secret'), false);
});

test('automatic skips disabled, experimental, unsupported and credential-required sources', async function eligibleSources() {
  const called = [];
  const definitions = [definition('disabled'), definition('experimental', {experimentalPlatforms: ['163']}),
    definition('unsupported', {platforms: ['qq']}), definition('licensed',
      {credentials: [{key: 'license', label: '授权码', requiredPlatforms: ['163']}]}), definition('available')];
  const handlerMap = {};
  for (const item of definitions) handlerMap[item.id] = async () => { called.push(item.id); return playable; };
  const resolve = createPlaybackResolver({definitions, handlerMap});
  const result = await resolve({...song, disabledSources: ['disabled']});
  assert.equal(result.providerId, 'available');
  assert.deepEqual(called, ['available']);
});

test('manual source retains useful business failure instead of retrying other sources', async function manualFailure() {
  const resolve = createPlaybackResolver({definitions: [definition('manual')], handlerMap: {
    manual: async () => { throw new SourceError('AUTH_EXPIRED', '授权已过期'); },
  }});
  await assert.rejects(resolve({...song, source: 'manual'}), {code: 'AUTH_EXPIRED'});
});

test('credentials remain scoped to the selected source and missing credentials are reported', async function scopedCredentials() {
  const item = definition('licensed', {credentials: [{key: 'license', label: '授权码', requiredPlatforms: ['163']}]});
  let received;
  const resolve = createPlaybackResolver({definitions: [item], handlerMap: {
    licensed: async (_song, context) => { received = context.credentials; return playable; },
  }});
  await assert.rejects(resolve({...song, source: 'licensed'}), {code: 'CREDENTIAL_REQUIRED'});
  await resolve({...song, source: 'licensed', credentials: {licensed: {license: 'my-key'}, another: {license: 'other-key'}}});
  assert.deepEqual({...received}, {license: 'my-key'});
  await assert.rejects(resolve({...song, credentials: {licensed: {license: 'bad\nkey'}}}), {code: 'INVALID_CREDENTIALS'});
});

test('invalid metadata, source lists and prototype platform names are rejected before network access', async function invalidInputs() {
  const resolve = createPlaybackResolver();
  for (const invalid of [{platform: 'toString'}, {id: ''}, {quality: 'unknown'}, {duration: -1},
    {name: 'invalid\nname'}, {excludedSources: Array(33).fill('qing_music')}, {source: 123}]) {
    await assert.rejects(resolve({...song, ...invalid}), SourceError);
  }
});

test('new sources do not increase each automatic race beyond four requests', async function concurrencyLimit() {
  let active = 0;
  let maximum = 0;
  const definitions = [];
  const handlerMap = {};
  for (let index = 0; index < 8; index++) {
    const id = `source_${index}`;
    definitions.push(definition(id));
    handlerMap[id] = async function requestSource() {
      active++;
      maximum = Math.max(active, maximum);
      await new Promise(resolve => setTimeout(resolve, 5));
      active--;
      if (index === 7) return playable;
      throw new SourceError('NO_SONG', '无歌曲');
    };
  }
  const resolve = createPlaybackResolver({definitions, handlerMap});
  assert.equal((await resolve(song)).providerId, 'source_7');
  assert.equal(maximum, 4);
  assert.equal(active, 0);
});

test('quality fallback remains bounded and never upgrades a standard request', async function qualityFallback() {
  const qualities = [];
  const resolve = createPlaybackResolver({definitions: [definition('none')], handlerMap: {
    none: async value => { qualities.push(value.quality); throw new SourceError('NO_SONG', '无歌曲'); },
  }});
  await assert.rejects(resolve({...song, quality: 'jymaster'}), {code: 'SOURCES_UNAVAILABLE'});
  assert.deepEqual(qualities, ['jymaster', 'lossless', 'exhigh', 'standard']);
  qualities.length = 0;
  await assert.rejects(resolve({...song, quality: 'standard'}), SourceError);
  assert.deepEqual(qualities, ['standard']);
});

test('cancellation and deadline stop active upstream tasks', async function cancellation() {
  const resolve = createPlaybackResolver({definitions: [definition('slow')], handlerMap: {slow: waitForCancellation}, timeoutMs: 25});
  const controller = new AbortController();
  const pending = resolve(song, {signal: controller.signal});
  controller.abort();
  await assert.rejects(pending, {code: 'RESOLVE_CANCELLED'});
  const started = Date.now();
  await assert.rejects(resolve(song), {code: 'RESOLVE_TIMEOUT'});
  assert.ok(Date.now() - started < 1000);
});

test('Qing sends the actual body hash and matching v1.4.1 HMAC signature', async function qingSignature(t) {
  const previous = process.env.QING_CLIENT_KEY;
  process.env.QING_CLIENT_KEY = 'fixed-test-key';
  t.after(() => {
    if (previous === undefined) delete process.env.QING_CLIENT_KEY;
    else process.env.QING_CLIENT_KEY = previous;
  });
  let request;
  const resolve = createPlaybackResolver({request: async (url, options) => {
    request = {url: String(url), ...options};
    return {status: 201, data: {code: 0, data: playable}};
  }});
  await resolve({...song, platform: 'qq', quality: 'hires', source: 'qing_music'});
  assert.equal(request.body.level, 'lossless');
  const headers = request.headers;
  const bodyHash = crypto.createHash('sha256').update(JSON.stringify(request.body)).digest('hex');
  const text = ['qingmusic-android', headers['X-Qing-Ts'], headers['X-Qing-Nonce'], 'POST', '/v1/music/resolve-url', bodyHash].join('\n');
  assert.equal(headers['X-Qing-Sign'], crypto.createHmac('sha256', 'fixed-test-key').update(text).digest('hex'));
});

test('HYW Unicode card key is encoded in query and not placed into a header', async function hywCardKey() {
  let request;
  const resolve = createPlaybackResolver({request: async (url, options) => {
    request = {url: new URL(url), ...options};
    return {status: 200, data: {code: 200, data: playable}};
  }});
  await resolve({...song, source: 'hyw', credentials: {hyw: {hywCardKey: '合法中文卡密'}}});
  assert.equal(request.url.searchParams.get('key'), '合法中文卡密');
  assert.equal(request.headers['X-Card-Key'], undefined);
});

test('Xinghai refreshes a token only once and does not refresh authorization failures', async function xinghaiToken() {
  let tokenCalls = 0;
  let musicCalls = 0;
  const resolve = createPlaybackResolver({request: async url => {
    if (String(url).includes('token.php')) {
      tokenCalls++;
      return {status: 200, data: {code: 200, data: {token: `xh3.test${tokenCalls}`}}};
    }
    musicCalls++;
    if (musicCalls === 1) return {status: 401, data: {code: 401, msg: 'token expired'}};
    return {status: 200, data: {code: 200, data: playable}};
  }});
  await resolve({...song, source: 'xinghai', credentials: {xinghai: {xinghaiLicenseKey: 'refresh-test'}}});
  assert.equal(tokenCalls, 2);
  assert.equal(musicCalls, 2);
  let calls = 0;
  const rejected = createPlaybackResolver({request: async url => {
    calls++;
    if (String(url).includes('token.php')) return {status: 200, data: {code: 200, data: {token: 'xh3.authorization'}}};
    return {status: 401, data: {code: 401, msg: 'license expired'}};
  }});
  await assert.rejects(rejected({...song, source: 'xinghai', credentials: {xinghai: {xinghaiLicenseKey: 'auth-failure-test'}}}), {code: 'XINGHAI_AUTH_REQUIRED'});
  assert.equal(calls, 2);
});

test('GD refuses cover versions and deduplicates the same effective bitrate', async function gdMatch() {
  const bitrates = [];
  const resolve = createPlaybackResolver({request: async url => {
    const target = new URL(url);
    if (target.searchParams.get('types') === 'search') return {status: 200, data: [
      {id: 1, name: song.name, artist: ['cover artist']},
      {id: 2, name: song.name, artist: [song.artist], duration: 326},
    ]};
    assert.equal(target.searchParams.get('id'), '2');
    bitrates.push(target.searchParams.get('br'));
    return {status: 200, data: playable};
  }});
  await resolve({...song, platform: 'qq', quality: '320k', source: 'gd_studio'});
  assert.deepEqual(bitrates, ['320']);
});

test('invalid audio URLs, encrypted formats and header injection are rejected', function audioValidation() {
  for (const value of [{url: 'file:///etc/passwd'}, {url: 'https://u:p@example.com/a.mp3'},
    {...playable, format: 'mflac'}, {...playable, encrypted: true},
    {...playable, playbackHeaders: {Referer: 'good\nbad'}}, {...playable, playbackHeaders: {Host: 'private'}}]) {
    assert.throws(() => resolved(value, 'test'), SourceError);
  }
});

test('fixed upstream allowlist rejects arbitrary destinations before sending a request', async function upstreamAllowlist() {
  await assert.rejects(fetchJson('https://127.0.0.1/private'), {code: 'INVALID_UPSTREAM'});
  await assert.rejects(fetchJson('https://api.chksz.com:444/'), {code: 'INVALID_UPSTREAM'});
});

test('upstream response limit cancels the reader and refuses oversized JSON', async function responseLimit(t) {
  const original = globalThis.fetch;
  let cancelled = false;
  const reader = {
    read: async () => ({done: false, value: new Uint8Array(512 * 1024 + 1)}),
    cancel: async () => { cancelled = true; },
  };
  globalThis.fetch = async function requestLargeResponse(_url, options) {
    assert.equal(options.redirect, 'error');
    return {status: 200, body: {getReader: () => reader}};
  };
  t.after(() => { globalThis.fetch = original; });
  await assert.rejects(fetchJson('https://api.chksz.com/api/test'), {code: 'RESPONSE_TOO_LARGE'});
  assert.equal(cancelled, true);
  await assert.rejects(fetchJson('https://api.chksz.com/api/test', {maxBytes: 5 * 1024 * 1024}), {code: 'INVALID_RESPONSE_LIMIT'});
});

test('HTTP service exposes only health, capabilities and validated resolve routes', async function routes(t) {
  const base = await fixture(t, {resolver: async () => ({protocolVersion: 1, ...playable, providerId: 'new_source'})});
  assert.equal((await fetch(`${base}/health`)).status, 200);
  const capabilities = await (await fetch(`${base}/api/sources`)).json();
  assert.equal(capabilities.protocolVersion, 1);
  assert.equal((await fetch(`${base}/manifest.json`)).status, 404);
  const result = await fetch(`${base}/api/resolve`, {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(song)});
  assert.equal(result.status, 200);
  assert.equal((await result.json()).providerId, 'new_source');
});

test('HTTP service rejects malformed, wrong type and oversized requests', async function requestValidation(t) {
  const base = await fixture(t);
  const post = body => fetch(`${base}/api/resolve`, {method: 'POST', headers: {'Content-Type': 'application/json'}, body});
  assert.equal((await post('{')).status, 400);
  assert.equal((await post('x'.repeat(65537))).status, 413);
  assert.equal((await fetch(`${base}/api/resolve`, {method: 'POST', body: 'text'})).status, 415);
});

test('busy service refuses new work and cancellation releases the active slot', async function serverConcurrency(t) {
  let begin;
  let end;
  const begun = new Promise(resolve => { begin = resolve; });
  const ended = new Promise(resolve => { end = resolve; });
  const resolver = async (_input, {signal}) => {
    begin();
    try { await waitForCancellation(song, {signal}); }
    finally { end(); }
  };
  const base = await fixture(t, {resolver, maxConcurrent: 1});
  const request = http.request(`${base}/api/resolve`, {method: 'POST', headers: {'Content-Type': 'application/json'}});
  request.on('error', () => {});
  request.end(JSON.stringify(song));
  await begun;
  const busy = await fetch(`${base}/api/resolve`, {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(song)});
  assert.equal(busy.status, 503);
  request.destroy();
  await ended;
  assert.equal((await fetch(`${base}/health`)).status, 200);
});

test('unexpected errors do not expose upstream URLs or credentials', async function errorPrivacy(t) {
  const base = await fixture(t, {resolver: async () => { throw new Error('https://upstream.example/?key=secret'); }});
  const response = await fetch(`${base}/api/resolve`, {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(song)});
  const body = await response.text();
  assert.equal(response.status, 502);
  assert.equal(body.includes('secret'), false);
  assert.equal(body.includes('upstream.example'), false);
});

test('sixteen dynamic credential fields work and inherited values never satisfy a required field', async function credentialLimits() {
  const fields = [];
  const values = {};
  for (let index = 0; index < 16; index++) {
    fields.push({key: `field${index}`, label: `字段${index}`, requiredPlatforms: ['163']});
    values[`field${index}`] = `value${index}`;
  }
  const item = definition('dynamic', {credentials: fields});
  const resolve = createPlaybackResolver({definitions: [item], handlerMap: {dynamic: async () => playable}});
  assert.equal((await resolve({...song, source: 'dynamic', credentials: {dynamic: values}})).providerId, 'dynamic');
  await assert.rejects(resolve({...song, source: 'dynamic', credentials: {dynamic: {...values, seventeenth: 'extra'}}}), {code: 'INVALID_CREDENTIALS'});
  const prototypeField = definition('constructor', {credentials: [{key: 'constructor', label: '凭据', requiredPlatforms: ['163']}]});
  const withPrototypeField = createPlaybackResolver({definitions: [prototypeField], handlerMap: {constructor: async () => playable}});
  await assert.rejects(withPrototypeField({...song, source: 'constructor'}), {code: 'CREDENTIAL_REQUIRED'});
  assert.equal((await withPrototypeField({...song, source: 'constructor', credentials: {constructor: {constructor: 'actual-value'}}})).providerId, 'constructor');
});

test('invalid and duplicate new source definitions fail before serving a broken capability list', function sourceDefinitionValidation() {
  for (const definitions of [[definition('same'), definition('same')], [definition('automatic')],
    [definition('missing', {name: undefined})], [definition('invalid', {platforms: ['163', '163']})],
    [definition('fields', {credentials: Array(17).fill({key: 'key', label: '密钥', requiredPlatforms: []})})]]) {
    assert.throws(() => createPlaybackResolver({definitions}), {code: 'INVALID_SOURCE_CONFIG'});
  }
});

test('Xinghai structured token errors refresh once and an invalid token response is never cached', async function structuredTokenErrors() {
  let tokenCalls = 0;
  let musicCalls = 0;
  const resolve = createPlaybackResolver({request: async function requestToken(url, options) {
    if (String(url).includes('token.php')) {
      tokenCalls++;
      assert.equal(options.maxBytes, 65536);
      return {status: 200, data: {code: 200, data: {token: `xh3.structured${tokenCalls}`}}};
    }
    musicCalls++;
    if (musicCalls === 1) return {status: 200, data: {code: 403, auth: {tk_mismatch: true}}};
    return {status: 200, data: {code: 200, data: playable}};
  }});
  await resolve({...song, source: 'xinghai', credentials: {xinghai: {xinghaiLicenseKey: 'structured-refresh'}}});
  assert.equal(tokenCalls, 2);
  assert.equal(musicCalls, 2);
  let invalidCalls = 0;
  const invalid = createPlaybackResolver({request: async () => {
    invalidCalls++;
    return {status: 500, data: {code: 500, data: {token: 'xh3.invalid-status'}}};
  }});
  const input = {...song, source: 'xinghai', credentials: {xinghai: {xinghaiLicenseKey: 'invalid-token-status'}}};
  await assert.rejects(invalid(input), {code: 'TOKEN_INVALID'});
  await assert.rejects(invalid(input), {code: 'TOKEN_INVALID'});
  assert.equal(invalidCalls, 2);
});

test('partial request disconnects and oversized chunked bodies keep the service usable', async function partialRequests(t) {
  const base = await fixture(t);
  const partial = http.request(`${base}/api/resolve`, {method: 'POST', headers: {'Content-Type': 'application/json'}});
  partial.on('error', () => {});
  partial.write('{');
  await new Promise(resolve => setTimeout(resolve, 10));
  partial.destroy();
  const status = await new Promise(function chunkedRequest(resolve, reject) {
    const request = http.request(`${base}/api/resolve`, {method: 'POST', headers: {'Content-Type': 'application/json', 'Transfer-Encoding': 'chunked'}});
    request.on('response', function received(response) {
      response.resume();
      response.once('end', () => resolve(response.statusCode));
    });
    request.on('error', reject);
    request.end('x'.repeat(65537));
  });
  assert.equal(status, 413);
  assert.equal((await fetch(`${base}/health`)).status, 200);
});

test('bounded source capabilities validate lengths and omit internal configuration', function boundedCapabilities() {
  const definitions = [];
  for (let sourceIndex = 0; sourceIndex < 32; sourceIndex++) {
    const credentials = [];
    for (let fieldIndex = 0; fieldIndex < 16; fieldIndex++) {
      credentials.push({key: `field${fieldIndex}`, label: '字'.repeat(80), requiredPlatforms: ['qq', '163', 'kugou']});
    }
    definitions.push(definition(`source_${sourceIndex}`, {name: '字'.repeat(80), description: '字'.repeat(512),
      credentials, internalSecret: 'never-publish-this-value'}));
  }
  const capabilities = getCapabilities(definitions);
  assert.equal(capabilities.sources.length, 32);
  assert.equal(capabilities.sources[0].credentials.length, 16);
  const serialized = JSON.stringify(capabilities);
  assert.ok(Buffer.byteLength(serialized) <= 512 * 1024);
  assert.equal(serialized.includes('never-publish-this-value'), false);
  assert.throws(() => getCapabilities([definition('too_long', {description: '字'.repeat(513)})]), {code: 'INVALID_SOURCE_CONFIG'});
  assert.throws(() => getCapabilities([definition('too_long', {name: '字'.repeat(81)})]), {code: 'INVALID_SOURCE_CONFIG'});
});

test('eight concurrent four-source maximum responses fit the deployment memory budget', function boundedMemory() {
  // 独立进程避免其他用例的内存影响结果；限制与部署中的 old-space 保持一致。
  const sourceModule = new URL('./sources.mjs', import.meta.url).href;
  const networkModule = new URL('./network.mjs', import.meta.url).href;
  const script = `
    import {createPlaybackResolver} from ${JSON.stringify(sourceModule)};
    import {resolved} from ${JSON.stringify(networkModule)};
    const limit = 512 * 1024;
    const template = {code:200, data:{url:'https://audio.example/song.mp3', unused:''}};
    template.data.unused = 'x'.repeat(limit - Buffer.byteLength(JSON.stringify(template)));
    const payload = JSON.stringify(template);
    globalThis.fetch = async function response() { return new Response(payload, {status:200}); };
    const definitions = [], handlerMap = {};
    for (let index = 0; index < 4; index++) {
      const id = 'source_' + index;
      definitions.push({id, name:id, platforms:['163'], group:0, credentials:[]});
      handlerMap[id] = async function handle(song, context) {
        const reply = await context.request('https://api.chksz.com/api/test', {signal:context.signal});
        return resolved(reply.data, id);
      };
    }
    const resolve = createPlaybackResolver({definitions, handlerMap});
    const tasks = [];
    for (let index = 0; index < 8; index++) tasks.push(resolve({platform:'163', id:'song', quality:'exhigh'}));
    const replies = await Promise.all(tasks);
    console.log(JSON.stringify({resolutions:replies.length, responseBytes:Buffer.byteLength(payload), peakKiB:process.resourceUsage().maxRSS}));
  `;
  const result = spawnSync(process.execPath, ['--max-old-space-size=96', '--input-type=module', '-e', script],
    {encoding: 'utf8', timeout: 10000, maxBuffer: 64 * 1024});
  assert.equal(result.status, 0, result.stderr);
  const measured = JSON.parse(result.stdout);
  assert.equal(measured.resolutions, 8);
  assert.equal(measured.responseBytes, 512 * 1024);
  assert.ok(measured.peakKiB < 192 * 1024, `峰值超过容器预算：${measured.peakKiB} KiB`);
});
