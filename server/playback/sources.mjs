import crypto from 'node:crypto';
import {fetchJson, query, resolved, SourceError} from './network.mjs';

const tokens = new Map();
const platformCodes = {qq: 'tx', '163': 'wy', kugou: 'kg'};
const platforms = ['qq', '163', 'kugou'];
const validId = /^[a-z][a-z0-9_]{0,63}$/;
const sourceFailures = new Set([
  'API_KEY_REQUIRED', 'LICENSE_REQUIRED', 'SOURCE_UNSUPPORTED', 'HYW_KEY_INVALID',
  'QING_AUTH_UNCONFIGURED', 'UPSTREAM_NETWORK', 'XINGHAI_AUTH_REQUIRED',
  'QING_AUTH_INVALID', 'TOKEN_INVALID',
]);

// 定义同时决定能力列表和自动分组；新增源只需补定义和下方 handlers。
export const sources = [
  {id: 'qing_music', name: 'QingMusic', description: '服务端签名认证', platforms,
    group: 0, credentials: []},
  {id: 'xinghai', name: '星海', description: '服务端令牌，QQ 需要授权卡密', platforms,
    group: 0, credentials: [{key: 'xinghaiLicenseKey', label: '授权卡密', requiredPlatforms: ['qq'], ascii: true}]},
  {id: 'hyw', name: 'HYWmusic 公益版', description: '网易云可用，QQ 实验线路', platforms: ['163', 'qq'],
    experimentalPlatforms: ['qq'], group: 0,
    credentials: [{key: 'hywCardKey', label: 'Card Key', requiredPlatforms: []}]},
  {id: 'gd_studio', name: 'GDStudio', description: '网易云解析及跨平台同曲匹配', platforms,
    group: 1, credentials: []},
  {id: 'chksz', name: 'ChKSz', description: '使用个人 API Key', platforms,
    group: 0, credentials: [{key: 'apiKey', label: 'API Key', requiredPlatforms: platforms}]},
];

function defaultCredentials(sourceId) {
  switch (sourceId) {
    case 'chksz': return {apiKey: process.env.CHKSZ_API_KEY || ''};
    case 'hyw': return {hywCardKey: process.env.HYW_CARD_KEY || '6C1F-53W0-GRKI-EVFG'};
    case 'xinghai': return {xinghaiLicenseKey: process.env.XINGHAI_LICENSE_KEY || ''};
    default: return {};
  }
}

function aggregateQuality(quality) {
  return ({standard: '128k', exhigh: '320k', lossless: 'flac', jyeffect: 'hires',
    sky: 'master', jymaster: 'master'})[quality] || quality;
}

async function qing(song, context) {
  const key = process.env.QING_CLIENT_KEY;
  if (!key) throw new SourceError('QING_AUTH_UNCONFIGURED', '服务器未配置 QingMusic 认证');
  let level = song.quality;
  if (song.platform !== '163') {
    const levels = {'128k': 'standard', '320k': 'exhigh', flac: 'lossless',
      hires: song.platform === 'qq' ? 'lossless' : 'hires',
      master: song.platform === 'qq' ? 'jymaster' : 'clear'};
    level = levels[song.quality] || 'lossless';
  }
  const body = {source: platformCodes[song.platform], rid: song.id, level};
  const stamp = String(Date.now());
  const nonce = crypto.randomBytes(16).toString('hex');
  const bodyHash = crypto.createHash('sha256').update(JSON.stringify(body)).digest('hex');
  const signature = ['qingmusic-android', stamp, nonce, 'POST', '/v1/music/resolve-url', bodyHash].join('\n');
  const headers = {'X-Qing-App-Id': 'qingmusic-android', 'X-Qing-App-Version': '1.4.1',
    'X-Qing-App-Version-Code': '25', 'X-Qing-App-Package': 'com.qingmusic.changqing',
    'X-Qing-Device-Id': context.device, 'X-Qing-Ts': stamp, 'X-Qing-Nonce': nonce,
    'X-Qing-Sign': crypto.createHmac('sha256', key).update(signature).digest('hex')};
  const reply = await context.request('https://musicserver.haitangw.cc/v1/music/resolve-url',
    {body, headers, signal: context.signal});
  const code = String(reply.data?.code || '');
  if (code === 'APP_UPGRADE_REQUIRED' || code.startsWith('APP_SIGN_')) {
    throw new SourceError('QING_AUTH_INVALID', 'QingMusic 服务端认证已失效');
  }
  if (reply.status < 200 || reply.status >= 300 || String(reply.data?.code) !== '0') {
    throw new SourceError('QING_REJECTED', 'QingMusic 当前请求不可用');
  }
  return resolved(reply.data, 'qing_music');
}

async function hyw(song, context) {
  const key = context.credentials.hywCardKey || '';
  let quality = aggregateQuality(song.quality);
  if (['master', 'hires'].includes(quality)) quality = 'flac24bit';
  const url = query('http://103.79.184.97/api/music/url', {source: platformCodes[song.platform],
    platform: platformCodes[song.platform], songId: song.id, songmid: song.id, quality,
    name: song.name, singer: song.artist, albumName: song.album, albumId: song.albumId,
    interval: song.duration, key});
  const reply = await context.request(url, {headers: {'User-Agent': 'lx-music-request/1.0.0'}, signal: context.signal});
  if (reply.status === 401 || String(reply.data?.code) === '401') {
    throw new SourceError('HYW_KEY_INVALID', 'HYW 卡密无效或已过期');
  }
  if (reply.status !== 200 || String(reply.data?.code) !== '200') {
    throw new SourceError('HYW_REJECTED', 'HYW 当前线路不可用');
  }
  return resolved(reply.data, 'hyw');
}

function tokenKey(license, device) {
  return crypto.createHash('sha256').update(JSON.stringify([license, device])).digest('hex');
}

async function token(license, context) {
  const cacheKey = tokenKey(license, context.device);
  const entry = tokens.get(cacheKey);
  if (entry && entry.until > Date.now()) return entry.value;
  // 不共享取消 Promise；上限限制多用户令牌长期驻留，失败不会写入缓存。
  if (tokens.size >= 16) tokens.delete(tokens.keys().next().value);
  const url = query('https://yy1.zddyr.top/lx/api/token.php', {device_id: context.device});
  const reply = await context.request(url, {headers: {'X-Client': 'XingHaiMusicSource/v3.2.20 (Android)'},
    signal: context.signal, timeout: 3000, maxBytes: 64 * 1024});
  if (context.signal.aborted) throw new SourceError('RESOLVE_CANCELLED', '播放解析已取消');
  const value = reply.data?.data?.token || reply.data?.token;
  if (reply.status < 200 || reply.status >= 300 || !['0', '200'].includes(String(reply.data?.code)) ||
      typeof value !== 'string' || !/^xh3\.[\x21-\x7e]{1,4092}$/.test(value)) {
    throw new SourceError('TOKEN_INVALID', '星海未返回有效令牌');
  }
  if (tokens.size >= 16) tokens.delete(tokens.keys().next().value);
  tokens.set(cacheKey, {value, until: Date.now() + 180000});
  return value;
}

function tokenNeedsRefresh(reply) {
  const auth = reply.data?.auth;
  if (auth && typeof auth === 'object') {
    const tokenError = auth.tk_error;
    if (auth.tk_mismatch === true || auth.device_id === 'untrusted-token' ||
        (tokenError !== undefined && tokenError !== null && tokenError !== false && tokenError !== '')) return true;
  }
  const message = String(reply.data?.msg || reply.data?.message || '').toLowerCase();
  // 授权卡密与短期令牌是不同错误；授权失败不会刷新或重复请求。
  return /token|令牌/.test(message) && [401, 403].includes(Number(reply.data?.code || reply.status));
}

async function xinghai(song, context) {
  const license = context.credentials.xinghaiLicenseKey || '';
  const url = query('https://yy1.zddyr.top/lx/api/', {source: song.platform === 'qq' ? 'qq' : platformCodes[song.platform],
    songmid: song.id, quality: aggregateQuality(song.quality), name: song.name, singer: song.artist,
    albumName: song.album, albumMid: song.albumId, interval: song.duration,
    ...(song.platform === 'kugou' ? {hash: song.id, mainHash: song.id, albumId: song.albumId} : {})});
  for (let attempt = 0; attempt < 2; attempt++) {
    const value = await token(license, context);
    const reply = await context.request(url, {headers: {'X-Client': 'XingHaiMusicSource/v3.2.20 (Android)',
      'X-Token': value, ...(license ? {'X-License': license} : {})}, signal: context.signal});
    if (attempt === 0 && tokenNeedsRefresh(reply)) {
      tokens.delete(tokenKey(license, context.device));
      continue;
    }
    if ([401, 403].includes(Number(reply.data?.code || reply.status))) {
      throw new SourceError('XINGHAI_AUTH_REQUIRED', '星海线路或授权不可用');
    }
    if (reply.status !== 200 || String(reply.data?.code) !== '200') {
      throw new SourceError('XINGHAI_REJECTED', '星海当前线路不可用');
    }
    return resolved(reply.data, 'xinghai');
  }
  throw new SourceError('TOKEN_INVALID', '星海令牌刷新失败');
}

function normalized(value) {
  return String(value || '').normalize('NFKC').toLowerCase().replace(/[\s\u200b-\u200d]/g, '');
}

function sameArtists(actual, expected) {
  const found = String(actual || '').split(/\s*[/、,&]\s*/).map(normalized);
  const requested = String(expected || '').split(/\s*[/、,&]\s*/).map(normalized);
  return requested.length > 0 && requested.every(name => name && found.includes(name));
}

function matchingGdId(rows, song) {
  for (const row of rows.slice(0, 20)) {
    if (!row || typeof row !== 'object' || Array.isArray(row) ||
        (row.source !== undefined && row.source !== 'netease') || !/^[0-9]{1,20}$/.test(String(row.id || ''))) continue;
    const artist = Array.isArray(row.artist) ? row.artist.join(' / ') : row.artist;
    const duration = Number(row.extra_data?.duration || row.duration || 0);
    const seconds = duration > 10000 ? duration / 1000 : duration;
    if (normalized(row.name) === normalized(song.name) && sameArtists(artist, song.artist) &&
        (!seconds || !song.duration || Math.abs(seconds - song.duration) <= 10)) {
      return String(row.id || '');
    }
  }
  throw new SourceError('GD_MATCH_NOT_FOUND', '网易云未找到原唱及版本相符的歌曲');
}

async function gd(song, context) {
  let id = song.id;
  if (song.platform !== '163') {
    if (!song.name.trim() || !song.artist.trim() || song.artist.trim() === '未知歌手') {
      throw new SourceError('GD_MATCH_NOT_FOUND', '缺少原曲元数据');
    }
    const cacheKey = `${song.platform}:${song.id}`;
    id = context.matches.get(cacheKey);
    if (!id) {
      const url = query('https://music-api.gdstudio.xyz/api.php', {types: 'search', source: 'netease',
        name: `${song.name} ${song.artist}`, count: 20, pages: 1});
      const reply = await context.request(url, {signal: context.signal});
      id = matchingGdId(Array.isArray(reply.data) ? reply.data : [], song);
      context.matches.set(cacheKey, id);
    }
  }
  const quality = aggregateQuality(song.quality);
  const br = ({'128k': 128, '320k': 320, flac: 740, hires: 999, master: 999})[quality] || 320;
  for (const bitrate of br === 999 ? [999, 740] : [br]) {
    if (context.bitrates.has(bitrate)) continue;
    context.bitrates.add(bitrate);
    const url = query('https://music-api.gdstudio.xyz/api.php', {types: 'url', source: 'netease', id, br: bitrate});
    const reply = await context.request(url, {signal: context.signal});
    if (reply.status !== 200) throw new SourceError('GD_UNAVAILABLE', 'GDStudio 当前请求不可用');
    try { return resolved(reply.data, 'gd_studio'); }
    catch (error) { if (bitrate !== 999 || sourceFailures.has(error.code)) throw error; }
  }
  throw new SourceError('GD_QUALITY_FAILED', 'GDStudio 本轮音质均不可用');
}

async function chksz(song, context) {
  const endpoint = {'163': '163_music', qq: 'qq_music', kugou: 'kugou_music'}[song.platform];
  let params;
  if (song.platform === '163') params = {id: song.id, level: song.quality, type: 'json'};
  else if (song.platform === 'qq') params = {mid: song.id, size: song.quality};
  else params = {id: song.id, size: song.quality};
  const url = query(`https://api.chksz.com/api/${endpoint}`, {...params, apikey: context.credentials.apiKey});
  const reply = await context.request(url, {signal: context.signal});
  if (reply.status !== 200 || String(reply.data?.code) !== '200') {
    throw new SourceError('CHKSZ_REJECTED', 'ChKSz 授权或资源不可用');
  }
  return resolved(reply.data, 'chksz');
}

const handlers = {qing_music: qing, xinghai, hyw, gd_studio: gd, chksz};

/** 返回可扩展音源能力，不包含任何运行时凭据。SHIXIAOYANG，2026/11/20。 */
export function getCapabilities(definitions = sources) {
  validateDefinitions(definitions);
  const revision = process.env.PLAYBACK_REVISION || '20261120.1';
  if (!validText(revision, 64)) throw new SourceError('INVALID_SOURCE_CONFIG', '音源能力版本无效');
  const publicSources = [];
  for (const definition of definitions) {
    if (definition.enabled === false) continue;
    const credentials = [];
    for (const field of definition.credentials || []) {
      credentials.push({key: field.key, label: field.label, requiredPlatforms: [...field.requiredPlatforms]});
    }
    // 仅公开协议字段，新增源的内部配置或运行时凭据不能随能力列表下发。
    publicSources.push({id: definition.id, name: definition.name, description: definition.description || '',
      platforms: [...definition.platforms], experimentalPlatforms: [...(definition.experimentalPlatforms || [])], credentials});
  }
  const capabilities = {protocolVersion: 1, revision, sources: publicSources};
  if (Buffer.byteLength(JSON.stringify(capabilities)) > 512 * 1024) {
    throw new SourceError('INVALID_SOURCE_CONFIG', '音源能力数据超过上限');
  }
  return capabilities;
}

function validateSong(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input) || !platforms.includes(input.platform) ||
      typeof input.id !== 'string' || input.id.length < 1 || input.id.length > 128 || /[\x00-\x1f\x7f]/.test(input.id)) {
    throw new SourceError('INVALID_SONG', '歌曲参数无效');
  }
  const song = {platform: input.platform, id: input.id, source: input.source ?? 'automatic'};
  if (typeof song.source !== 'string' || !validId.test(song.source)) throw new SourceError('INVALID_SOURCE', '音源标识无效');
  for (const key of ['name', 'artist', 'album', 'albumId']) {
    const value = input[key] ?? '';
    if (typeof value !== 'string' || value.length > 512 || /[\x00-\x1f\x7f]/.test(value)) {
      throw new SourceError('INVALID_SONG', '歌曲元数据无效');
    }
    song[key] = value;
  }
  song.duration = input.duration ?? 0;
  if (!Number.isInteger(song.duration) || song.duration < 0 || song.duration > 86400) throw new SourceError('INVALID_SONG', '歌曲时长无效');
  song.quality = input.quality ?? (song.platform === '163' ? 'exhigh' : '320k');
  const qualityOrder = song.platform === '163' ? ['jymaster', 'sky', 'jyeffect', 'hires', 'lossless', 'exhigh', 'standard'] :
    ['master', 'hires', 'flac', '320k', '128k'];
  if (!qualityOrder.includes(song.quality)) throw new SourceError('INVALID_QUALITY', '音质参数无效');
  return song;
}

function sourceSet(value) {
  if (value === undefined) return new Set();
  if (!Array.isArray(value) || value.length > 32 || value.some(id => typeof id !== 'string' || !validId.test(id))) {
    throw new SourceError('INVALID_SOURCE', '音源列表无效');
  }
  return new Set(value);
}

function credentialsFor(input, definition) {
  if (input !== undefined && (!input || typeof input !== 'object' || Array.isArray(input) || Object.keys(input).length > 32)) {
    throw new SourceError('INVALID_CREDENTIALS', '音源凭据结构无效');
  }
  const saved = input && Object.hasOwn(input, definition.id) ? input[definition.id] : {};
  if (!saved || typeof saved !== 'object' || Array.isArray(saved) || Object.keys(saved).length > 16) {
    throw new SourceError('INVALID_CREDENTIALS', '音源凭据结构无效');
  }
  // 新音源可能使用 constructor 等合法字段名；无原型字典不会误把继承属性当凭据。
  const credentials = Object.assign(Object.create(null), defaultCredentials(definition.id));
  for (const field of definition.credentials || []) {
    const value = Object.hasOwn(saved, field.key) ? saved[field.key] : undefined;
    if (value === undefined || value === '') continue;
    if (typeof value !== 'string' || value.length > 1024 || /[\x00-\x1f\x7f]/.test(value) ||
        (field.ascii && /[^\x20-\x7e]/.test(value))) throw new SourceError('INVALID_CREDENTIALS', '音源凭据格式无效');
    credentials[field.key] = value.trim();
  }
  return credentials;
}

function eligibleSources(song, input, definitions, handlerMap) {
  const excluded = sourceSet(input.excludedSources);
  const disabled = sourceSet(input.disabledSources);
  const automatic = song.source === 'automatic';
  const selected = [];
  for (const definition of definitions) {
    const credentials = credentialsFor(input.credentials, definition);
    if (!automatic && definition.id !== song.source) continue;
    if (definition.enabled === false || excluded.has(definition.id) || disabled.has(definition.id) ||
        !Object.hasOwn(handlerMap, definition.id) || typeof handlerMap[definition.id] !== 'function' ||
        !definition.platforms.includes(song.platform)) continue;
    const missing = (definition.credentials || []).find(field => field.requiredPlatforms.includes(song.platform) && !credentials[field.key]);
    if (missing && !automatic) throw new SourceError('CREDENTIAL_REQUIRED', `${definition.name}需要${missing.label}`);
    if (missing || (automatic && definition.experimentalPlatforms?.includes(song.platform))) continue;
    selected.push({...definition, credentials});
  }
  if (!selected.length) throw new SourceError('SOURCE_UNAVAILABLE', automatic ? '当前没有可用音源' : '所选音源不可用或不支持当前平台');
  return selected;
}

function qualityCandidates(song) {
  if (song.source !== 'automatic') return [song.quality];
  const order = song.platform === '163' ? ['jymaster', 'sky', 'jyeffect', 'hires', 'lossless', 'exhigh', 'standard'] :
    ['master', 'hires', 'flac', '320k', '128k'];
  const fallbacks = song.platform === '163' ? ['lossless', 'exhigh', 'standard'] : ['flac', '320k', '128k'];
  const values = [song.quality];
  for (const quality of fallbacks) {
    if (order.indexOf(quality) > order.indexOf(song.quality)) values.push(quality);
  }
  return values;
}

function effectiveQuality(source, platform, quality) {
  if (source === 'gd_studio') return ({'128k': 128, '320k': 320, flac: 740, hires: 999, master: 999})[aggregateQuality(quality)] || 320;
  if (source === 'hyw' && ['hires', 'master'].includes(aggregateQuality(quality))) return 'flac24bit';
  if (source === 'qing_music' && platform === 'qq' && quality === 'hires') return 'lossless';
  return quality;
}

async function raceSources(group, song, context, state) {
  const race = new AbortController();
  const cancel = () => race.abort();
  context.signal.addEventListener('abort', cancel, {once: true});
  if (context.signal.aborted) cancel();
  async function run(definition) {
    state.attempted.add(`${definition.id}:${effectiveQuality(definition.id, song.platform, song.quality)}`);
    const device = 'qt-' + crypto.createHash('sha256').update(JSON.stringify(definition.credentials)).digest('hex').slice(0, 32);
    try {
      const result = await context.handlers[definition.id](song, {...context, signal: race.signal, credentials: definition.credentials, device});
      if (race.signal.aborted) throw new SourceError('RESOLVE_CANCELLED', '播放解析已取消');
      return {...resolved(result, definition.id), providerName: definition.name, quality: song.quality};
    } catch (error) {
      if (state.failures.length < 32) state.failures.push({source: definition.id, code: error.code || 'UPSTREAM_ERROR'});
      if (sourceFailures.has(error.code)) state.excluded.add(definition.id);
      throw error;
    }
  }
  const tasks = group.map(run);
  try { return await Promise.any(tasks); }
  catch (error) {
    requireActive(context.signal);
    if (song.source !== 'automatic') throw error.errors?.[0] || error;
    return null;
  } finally {
    race.abort();
    context.signal.removeEventListener('abort', cancel);
    await Promise.allSettled(tasks);
  }
}

/** 创建可注入受控上游的解析入口，用于验证真实协议及新源发现。 */
export function createPlaybackResolver({definitions = sources, handlerMap = handlers, request = fetchJson, timeoutMs = 19000} = {}) {
  validateDefinitions(definitions);
  return async function resolve(input, {signal} = {}) {
    const song = validateSong(input);
    const selected = eligibleSources(song, input, definitions, handlerMap);
    const excluded = sourceSet(input.excludedSources);
    const deadline = new AbortController();
    const cancel = () => deadline.abort();
    signal?.addEventListener('abort', cancel, {once: true});
    if (signal?.aborted) cancel();
    const timer = setTimeout(() => deadline.abort(new SourceError('RESOLVE_TIMEOUT', '音源解析超时')), timeoutMs);
    const context = {signal: deadline.signal, request, handlers: handlerMap, matches: new Map(), bitrates: new Set()};
    const state = {excluded, attempted: new Set(), failures: []};
    try {
      return await resolveGroups(song, selected, context, state);
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener('abort', cancel);
      deadline.abort();
    }
  };
}

function validateDefinitions(definitions) {
  if (!Array.isArray(definitions) || definitions.length > 32) throw new SourceError('INVALID_SOURCE_CONFIG', '音源定义超过上限');
  const ids = new Set();
  for (const definition of definitions) {
    if (!definition || typeof definition.id !== 'string' || !validId.test(definition.id) ||
        definition.id === 'automatic' || ids.has(definition.id) || !validText(definition.name, 80) ||
        !validText(definition.description ?? '', 512, true) ||
        !validPlatforms(definition.platforms) || !validPlatforms(definition.experimentalPlatforms || [])) {
      throw new SourceError('INVALID_SOURCE_CONFIG', '音源定义无效');
    }
    ids.add(definition.id);
    const fields = definition.credentials || [];
    if (!Array.isArray(fields) || fields.length > 16) throw new SourceError('INVALID_SOURCE_CONFIG', '音源凭据字段超过上限');
    const keys = new Set();
    for (const field of fields) {
      if (!field || typeof field.key !== 'string' || !/^[A-Za-z][A-Za-z0-9_]{0,63}$/.test(field.key) ||
          keys.has(field.key) || !validText(field.label, 80) || !validPlatforms(field.requiredPlatforms)) {
        throw new SourceError('INVALID_SOURCE_CONFIG', '音源凭据定义无效');
      }
      keys.add(field.key);
    }
  }
}

function validText(value, maximum, allowEmpty = false) {
  return typeof value === 'string' && (allowEmpty || value.trim().length > 0) &&
    value.length <= maximum && !/[\x00-\x1f\x7f]/.test(value);
}

function validPlatforms(values) {
  return Array.isArray(values) && values.length <= 3 && new Set(values).size === values.length &&
    values.every(platform => platforms.includes(platform));
}

async function resolveGroups(song, selected, context, state) {
  const groupIds = [...new Set(selected.map(definition => definition.group || 0))].sort((left, right) => left - right);
  for (const quality of qualityCandidates(song)) {
    for (const groupId of groupIds) {
      requireActive(context.signal);
      const candidates = selected.filter(definition => (definition.group || 0) === groupId && !state.excluded.has(definition.id) &&
        !state.attempted.has(`${definition.id}:${effectiveQuality(definition.id, song.platform, quality)}`));
      const result = await resolveChunks(candidates, {...song, quality}, context, state);
      if (result) return {protocolVersion: 1, ...result};
    }
  }
  requireActive(context.signal);
  throw new SourceError('SOURCES_UNAVAILABLE', '当前音源均无法解析这首歌曲');
}

async function resolveChunks(candidates, song, context, state) {
  // 多于四个源时顺序处理批次，不因新增源提高单首歌的并发上限。
  for (let index = 0; index < candidates.length; index += 4) {
    requireActive(context.signal);
    const result = await raceSources(candidates.slice(index, index + 4), song, context, state);
    if (result) return result;
  }
  return null;
}

function requireActive(signal) {
  if (!signal.aborted) return;
  if (signal.reason instanceof SourceError) throw signal.reason;
  throw new SourceError('RESOLVE_CANCELLED', '播放解析已取消');
}

const defaultResolver = createPlaybackResolver();

/** 统一解析五种及后续新增音源，客户端只使用结果。SHIXIAOYANG，2026/11/20。 */
export async function resolvePlayback(input, options) {
  return defaultResolver(input, options);
}
