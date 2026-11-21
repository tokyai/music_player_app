(function installSourcePackage() {
  'use strict';

  const host = globalThis.KuzaiHost;
  const revision = '__PACKAGE_REVISION__';
  const platforms = ['qq', '163', 'kugou'];
  const platformCodes = {qq: 'tx', '163': 'wy', kugou: 'kg'};
  const validId = /^[a-z][a-z0-9_]{0,63}$/;
  const operations = new Map();
  const tokens = new Map();
  let disposed = false;
  const allowedOrigins = [
    'https://musicserver.haitangw.cc', 'https://qt.haitangw.net',
    'http://103.79.184.97', 'https://yy1.zddyr.top',
    'https://music-api.gdstudio.xyz', 'https://api.chksz.com',
  ];
  const sourceFailures = new Set([
    'API_KEY_REQUIRED', 'LICENSE_REQUIRED', 'SOURCE_UNSUPPORTED',
    'HYW_KEY_INVALID', 'QING_AUTH_INVALID', 'UPSTREAM_NETWORK',
    'XINGHAI_AUTH_REQUIRED', 'TOKEN_INVALID',
  ]);

  // 公开协议参数随签名包发布，个人 API Key 和授权卡密只能来自本地用户配置。
  const qingClientKey = 'qm-gw-7c1f4e9a2b8d5360e1a7c4f9b2d8036c';
  const publicHywCardKey = '6C1F-53W0-GRKI-EVFG';
  const sources = [
    {id: 'qing_music', name: 'QingMusic', description: '本地签名认证', platforms, group: 0, credentials: []},
    {id: 'xinghai', name: '星海', description: '上游令牌，QQ 需要授权卡密', platforms, group: 0,
      credentials: [{key: 'xinghaiLicenseKey', label: '授权卡密', requiredPlatforms: ['qq'], ascii: true}]},
    {id: 'hyw', name: 'HYWmusic 公益版', description: '网易云可用，QQ 实验线路',
      platforms: ['163', 'qq'], experimentalPlatforms: ['qq'], group: 0,
      credentials: [{key: 'hywCardKey', label: 'Card Key', requiredPlatforms: []}]},
    {id: 'gd_studio', name: 'GDStudio', description: '网易云解析及跨平台同曲匹配', platforms, group: 1, credentials: []},
    {id: 'chksz', name: 'ChKSz', description: '使用个人 API Key', platforms, group: 0,
      credentials: [{key: 'apiKey', label: 'API Key', requiredPlatforms: platforms}]},
  ];

  class SourceError extends Error {
    constructor(code, message) {
      super(message);
      this.code = code;
    }
  }

  function hasOwn(value, key) {
    return Object.prototype.hasOwnProperty.call(value, key);
  }

  function query(base, values) {
    const parts = [];
    for (const key of Object.keys(values)) {
      const value = values[key];
      if (value !== undefined && value !== null && value !== '') {
        parts.push(encodeURIComponent(key) + '=' + encodeURIComponent(String(value)));
      }
    }
    return base + (parts.length ? (base.indexOf('?') < 0 ? '?' : '&') + parts.join('&') : '');
  }

  function requireActive(context) {
    if (context.state.timedOut) throw new SourceError('RESOLVE_TIMEOUT', '音源解析超时');
    if (context.state.cancelled || context.scope.cancelled) {
      throw new SourceError('RESOLVE_CANCELLED', '播放解析已取消');
    }
  }

  async function requestJson(url, context, options = {}) {
    requireActive(context);
    const parameters = {
      url, method: options.bodyText === undefined ? 'GET' : 'POST',
      headers: Object.assign({'Accept': 'application/json', 'User-Agent': 'LX-Music-Mobile'}, options.headers || {}),
      timeoutMs: options.timeoutMs || 6500, maxBytes: options.maxBytes || 512 * 1024,
    };
    if (options.bodyText !== undefined) {
      parameters.bodyText = options.bodyText;
      parameters.headers['Content-Type'] = 'application/json; charset=utf-8';
    }
    let reply;
    try {
      reply = await host.request(context.scope.id, parameters);
    } catch (error) {
      requireActive(context);
      const code = error && String(error.code || '');
      if (/CANCEL/.test(code)) throw new SourceError('RESOLVE_CANCELLED', '播放解析已取消');
      if (/TOO_LARGE|RESPONSE_LIMIT/.test(code)) throw new SourceError('RESPONSE_TOO_LARGE', '上游响应过大');
      throw new SourceError(/TIMEOUT/.test(code) ? 'UPSTREAM_TIMEOUT' : 'UPSTREAM_NETWORK', '上游网络请求失败');
    }
    requireActive(context);
    if (!reply || !Number.isInteger(reply.status) || typeof reply.bodyText !== 'string') {
      throw new SourceError('UPSTREAM_INVALID_RESPONSE', '上游响应无效');
    }
    // native 按 UTF-8 字节限流；这里再次拒绝明显超大的字符串，避免误接桥接绕过限制。
    if (reply.bodyText.length > parameters.maxBytes) {
      throw new SourceError('RESPONSE_TOO_LARGE', '上游响应过大');
    }
    let data;
    try { data = JSON.parse(reply.bodyText); }
    catch (error) { throw new SourceError('UPSTREAM_INVALID_JSON', '上游返回非 JSON 内容'); }
    return {status: reply.status, data};
  }

  function aggregateQuality(quality) {
    return ({standard: '128k', exhigh: '320k', lossless: 'flac', jyeffect: 'hires',
      sky: 'master', jymaster: 'master'})[quality] || quality;
  }

  function qingLevel(platform, quality) {
    if (platform === '163') return quality;
    const levels = {'128k': 'standard', '320k': 'exhigh', flac: 'lossless',
      hires: platform === 'qq' ? 'lossless' : 'hires',
      master: platform === 'qq' ? 'jymaster' : 'clear'};
    return levels[quality] || 'lossless';
  }

  function hywQuality(quality) {
    const value = aggregateQuality(quality);
    return value === 'master' || value === 'hires' ? 'flac24bit' : value;
  }

  function gdBitrate(quality) {
    return ({'128k': 128, '320k': 320, flac: 740, hires: 999, master: 999})[aggregateQuality(quality)] || 320;
  }

  async function qing(song, context) {
    const bodyText = JSON.stringify({source: platformCodes[song.platform], rid: song.id,
      level: qingLevel(song.platform, song.quality)});
    const stamp = String(host.now());
    const nonce = host.randomHex(16);
    const signature = ['qingmusic-android', stamp, nonce, 'POST', '/v1/music/resolve-url', host.sha256(bodyText)].join('\n');
    const headers = {'X-Qing-App-Id': 'qingmusic-android', 'X-Qing-App-Version': '1.4.1',
      'X-Qing-App-Version-Code': '25', 'X-Qing-App-Package': 'com.qingmusic.changqing',
      'X-Qing-Device-Id': context.device, 'X-Qing-Ts': stamp, 'X-Qing-Nonce': nonce,
      'X-Qing-Sign': host.hmacSha256(qingClientKey, signature)};
    // native 按 bodyText 原文发送，签名内容和实际请求体必须完全相同。
    const reply = await requestJson('https://musicserver.haitangw.cc/v1/music/resolve-url', context, {bodyText, headers});
    const rawCode = reply.data && reply.data.code;
    const code = rawCode === undefined || rawCode === null ? '' : String(rawCode);
    if (code === 'APP_UPGRADE_REQUIRED' || code.indexOf('APP_SIGN_') === 0) {
      throw new SourceError('QING_AUTH_INVALID', 'QingMusic 本地认证已失效');
    }
    if (reply.status < 200 || reply.status >= 300 || code !== '0') {
      throw new SourceError('QING_REJECTED', 'QingMusic 当前请求不可用');
    }
    return resolved(reply.data, 'qing_music');
  }

  async function hyw(song, context) {
    const key = context.credentials.hywCardKey || publicHywCardKey;
    const url = query('http://103.79.184.97/api/music/url', {source: platformCodes[song.platform],
      platform: platformCodes[song.platform], songId: song.id, songmid: song.id,
      quality: hywQuality(song.quality), name: song.name, singer: song.artist,
      albumName: song.album, albumId: song.albumId, interval: song.duration, key});
    const reply = await requestJson(url, context, {headers: {'User-Agent': 'lx-music-request/1.0.0'}});
    if (reply.status === 401 || String(reply.data && reply.data.code) === '401') {
      throw new SourceError('HYW_KEY_INVALID', 'HYW 卡密无效或已过期');
    }
    if (reply.status !== 200 || String(reply.data && reply.data.code) !== '200') {
      throw new SourceError('HYW_REJECTED', 'HYW 当前线路不可用');
    }
    return resolved(reply.data, 'hyw');
  }

  function tokenKey(license, device) {
    return host.sha256(JSON.stringify([license, device]));
  }

  async function token(license, context) {
    const cacheKey = tokenKey(license, context.device);
    const entry = tokens.get(cacheKey);
    if (entry && entry.until > host.now()) return entry.value;
    const url = query('https://yy1.zddyr.top/lx/api/token.php', {device_id: context.device});
    const reply = await requestJson(url, context, {headers: {'X-Client': 'XingHaiMusicSource/v3.2.20 (Android)'},
      timeoutMs: 3000, maxBytes: 64 * 1024});
    const data = reply.data;
    const value = data && (data.data && data.data.token || data.token);
    if (reply.status < 200 || reply.status >= 300 || !['0', '200'].includes(String(data && data.code)) ||
        typeof value !== 'string' || !/^xh3\.[\x21-\x7e]{1,4092}$/.test(value)) {
      throw new SourceError('TOKEN_INVALID', '星海未返回有效令牌');
    }
    requireActive(context);
    if (tokens.size >= 16) tokens.delete(tokens.keys().next().value);
    tokens.set(cacheKey, {value, until: host.now() + 180000});
    return value;
  }

  function tokenNeedsRefresh(reply) {
    const data = reply.data;
    const auth = data && data.auth;
    if (auth && typeof auth === 'object') {
      const error = auth.tk_error;
      if (auth.tk_mismatch === true || auth.device_id === 'untrusted-token' ||
          (error !== undefined && error !== null && error !== false && error !== '')) return true;
    }
    const message = String(data && (data.msg || data.message) || '').toLowerCase();
    return /token|令牌/.test(message) && [401, 403].includes(Number(data && data.code || reply.status));
  }

  async function xinghai(song, context) {
    const license = context.credentials.xinghaiLicenseKey || '';
    const parameters = {source: song.platform === 'qq' ? 'qq' : platformCodes[song.platform],
      songmid: song.id, quality: aggregateQuality(song.quality), name: song.name,
      singer: song.artist, albumName: song.album, albumMid: song.albumId, interval: song.duration};
    if (song.platform === 'kugou') {
      parameters.hash = song.id; parameters.mainHash = song.id; parameters.albumId = song.albumId;
    }
    const url = query('https://yy1.zddyr.top/lx/api/', parameters);
    for (let attempt = 0; attempt < 2; attempt++) {
      const value = await token(license, context);
      const headers = {'X-Client': 'XingHaiMusicSource/v3.2.20 (Android)', 'X-Token': value};
      if (license) headers['X-License'] = license;
      const reply = await requestJson(url, context, {headers});
      if (attempt === 0 && tokenNeedsRefresh(reply)) {
        tokens.delete(tokenKey(license, context.device));
        continue;
      }
      if ([401, 403].includes(Number(reply.data && reply.data.code || reply.status))) {
        throw new SourceError('XINGHAI_AUTH_REQUIRED', '星海线路或授权不可用');
      }
      if (reply.status !== 200 || String(reply.data && reply.data.code) !== '200') {
        throw new SourceError('XINGHAI_REJECTED', '星海当前线路不可用');
      }
      return resolved(reply.data, 'xinghai');
    }
    throw new SourceError('TOKEN_INVALID', '星海令牌刷新失败');
  }

  function fullWidthAscii(character) {
    return String.fromCharCode(character.charCodeAt(0) - 0xfee0);
  }

  function normalized(value) {
    let text = String(value || '');
    if (typeof text.normalize === 'function') text = text.normalize('NFKC');
    else text = text.replace(/[\uff01-\uff5e]/g, fullWidthAscii);
    return text.toLowerCase().replace(/[\s\u200b-\u200d]/g, '');
  }

  function sameArtists(actual, expected) {
    const found = String(actual || '').split(/\s*[/、,&]\s*/).map(normalized);
    const requested = String(expected || '').split(/\s*[/、,&]\s*/).map(normalized);
    if (!requested.length) return false;
    for (const name of requested) {
      if (!name || !found.includes(name)) return false;
    }
    return true;
  }

  function matchingGdId(rows, song) {
    for (const row of rows.slice(0, 20)) {
      if (!row || typeof row !== 'object' || Array.isArray(row) ||
          (row.source !== undefined && row.source !== 'netease') || !/^[0-9]{1,20}$/.test(String(row.id || ''))) continue;
      const artist = Array.isArray(row.artist) ? row.artist.join(' / ') : row.artist;
      const duration = Number(row.extra_data && row.extra_data.duration || row.duration || 0);
      const seconds = duration > 10000 ? duration / 1000 : duration;
      if (normalized(row.name) === normalized(song.name) && sameArtists(artist, song.artist) &&
          (!seconds || !song.duration || Math.abs(seconds - song.duration) <= 10)) return String(row.id);
    }
    throw new SourceError('GD_MATCH_NOT_FOUND', '网易云未找到原唱及版本相符的歌曲');
  }

  async function gd(song, context) {
    let id = song.id;
    if (song.platform !== '163') {
      if (!song.name.trim() || !song.artist.trim() || song.artist.trim() === '未知歌手') {
        throw new SourceError('GD_MATCH_NOT_FOUND', '缺少原曲元数据');
      }
      const cacheKey = song.platform + ':' + song.id;
      id = context.matches.get(cacheKey);
      if (!id) {
        const search = query('https://music-api.gdstudio.xyz/api.php', {types: 'search', source: 'netease',
          name: song.name + ' ' + song.artist, count: 20, pages: 1});
        const reply = await requestJson(search, context);
        id = matchingGdId(Array.isArray(reply.data) ? reply.data : [], song);
        context.matches.set(cacheKey, id);
      }
    }
    const bitrate = gdBitrate(song.quality);
    for (const value of bitrate === 999 ? [999, 740] : [bitrate]) {
      if (context.bitrates.has(value)) continue;
      context.bitrates.add(value);
      const url = query('https://music-api.gdstudio.xyz/api.php', {types: 'url', source: 'netease', id, br: value});
      const reply = await requestJson(url, context);
      if (reply.status !== 200) throw new SourceError('GD_UNAVAILABLE', 'GDStudio 当前请求不可用');
      try { return resolved(reply.data, 'gd_studio'); }
      catch (error) { if (value !== 999 || sourceFailures.has(error.code)) throw error; }
    }
    throw new SourceError('GD_QUALITY_FAILED', 'GDStudio 本轮音质均不可用');
  }

  async function chksz(song, context) {
    const endpoint = {'163': '163_music', qq: 'qq_music', kugou: 'kugou_music'}[song.platform];
    let parameters;
    if (song.platform === '163') parameters = {id: song.id, level: song.quality, type: 'json'};
    else if (song.platform === 'qq') parameters = {mid: song.id, size: song.quality};
    else parameters = {id: song.id, size: song.quality};
    parameters.apikey = context.credentials.apiKey;
    const reply = await requestJson(query('https://api.chksz.com/api/' + endpoint, parameters), context);
    if (reply.status !== 200 || String(reply.data && reply.data.code) !== '200') {
      throw new SourceError('CHKSZ_REJECTED', 'ChKSz 授权或资源不可用');
    }
    return resolved(reply.data, 'chksz');
  }

  const handlers = {qing_music: qing, xinghai, hyw, gd_studio: gd, chksz};

  function validText(value, maximum, allowEmpty = false) {
    return typeof value === 'string' && (allowEmpty || value.trim().length > 0) &&
      value.length <= maximum && !/[\x00-\x1f\x7f]/.test(value);
  }

  function validateInput(input) {
    if (!input || typeof input !== 'object' || Array.isArray(input) || !platforms.includes(input.platform) ||
        !validText(input.id, 128)) throw new SourceError('INVALID_SONG', '歌曲参数无效');
    const song = {platform: input.platform, id: input.id,
      source: input.source === undefined || input.source === null ? 'automatic' : input.source};
    if (typeof song.source !== 'string' || !validId.test(song.source)) throw new SourceError('INVALID_SOURCE', '音源标识无效');
    for (const key of ['name', 'artist', 'album', 'albumId']) {
      const value = input[key] === undefined || input[key] === null ? '' : input[key];
      if (!validText(value, 512, true)) throw new SourceError('INVALID_SONG', '歌曲元数据无效');
      song[key] = value;
    }
    song.duration = input.duration === undefined || input.duration === null ? 0 : input.duration;
    if (!Number.isInteger(song.duration) || song.duration < 0 || song.duration > 86400) {
      throw new SourceError('INVALID_SONG', '歌曲时长无效');
    }
    const order = song.platform === '163' ? ['jymaster', 'sky', 'jyeffect', 'hires', 'lossless', 'exhigh', 'standard'] :
      ['master', 'hires', 'flac', '320k', '128k'];
    const defaultQuality = song.platform === '163' ? 'exhigh' : '320k';
    song.quality = input.quality === undefined || input.quality === null ? defaultQuality : input.quality;
    if (!order.includes(song.quality)) throw new SourceError('INVALID_QUALITY', '音质参数无效');
    return song;
  }

  function sourceSet(raw) {
    if (raw === undefined) return new Set();
    if (!Array.isArray(raw) || raw.length > 32) throw new SourceError('INVALID_SOURCE', '音源列表无效');
    for (const id of raw) {
      if (typeof id !== 'string' || !validId.test(id)) throw new SourceError('INVALID_SOURCE', '音源列表无效');
    }
    return new Set(raw);
  }

  function credentialsFor(raw, definition) {
    const saved = raw && hasOwn(raw, definition.id) ? raw[definition.id] : {};
    if (!saved || typeof saved !== 'object' || Array.isArray(saved) || Object.keys(saved).length > 16) {
      throw new SourceError('INVALID_CREDENTIALS', '音源凭据结构无效');
    }
    const result = Object.create(null);
    for (const field of definition.credentials || []) {
      const value = hasOwn(saved, field.key) ? saved[field.key] : '';
      if (!validText(value, 1024, true) || (field.ascii && /[^\x20-\x7e]/.test(value))) {
        throw new SourceError('INVALID_CREDENTIALS', '音源凭据格式无效');
      }
      result[field.key] = value.trim();
    }
    return result;
  }

  function eligibleSources(song, input) {
    const raw = input.credentials;
    if (raw !== undefined && (!raw || typeof raw !== 'object' || Array.isArray(raw) || Object.keys(raw).length > 32)) {
      throw new SourceError('INVALID_CREDENTIALS', '音源凭据结构无效');
    }
    const excluded = sourceSet(input.excludedSources);
    const disabled = sourceSet(input.disabledSources);
    const automatic = song.source === 'automatic';
    const selected = [];
    for (const definition of sources) {
      if (!automatic && definition.id !== song.source) continue;
      if (definition.enabled === false || excluded.has(definition.id) || disabled.has(definition.id) ||
          !hasOwn(handlers, definition.id) || !definition.platforms.includes(song.platform)) continue;
      const credentials = credentialsFor(raw, definition);
      let missing;
      for (const field of definition.credentials || []) {
        if (field.requiredPlatforms.includes(song.platform) && !credentials[field.key]) { missing = field; break; }
      }
      if (missing && !automatic) throw new SourceError('CREDENTIAL_REQUIRED', definition.name + '需要' + missing.label);
      if (missing || (automatic && (definition.experimentalPlatforms || []).includes(song.platform))) continue;
      selected.push(Object.assign({}, definition, {values: credentials}));
    }
    if (!selected.length) throw new SourceError('SOURCE_UNAVAILABLE', automatic ? '当前没有可用音源' : '所选音源不可用或不支持当前平台');
    return selected;
  }

  function qualityCandidates(song) {
    if (song.source !== 'automatic') return [song.quality];
    const order = song.platform === '163' ? ['jymaster', 'sky', 'jyeffect', 'hires', 'lossless', 'exhigh', 'standard'] :
      ['master', 'hires', 'flac', '320k', '128k'];
    const fallbacks = song.platform === '163' ? ['lossless', 'exhigh', 'standard'] : ['flac', '320k', '128k'];
    const result = [song.quality];
    for (const value of fallbacks) {
      if (order.indexOf(value) > order.indexOf(song.quality)) result.push(value);
    }
    return result;
  }

  function effectiveQuality(source, platform, quality) {
    if (source === 'qing_music') return qingLevel(platform, quality);
    if (source === 'hyw') return hywQuality(quality);
    if (source === 'gd_studio') return String(gdBitrate(quality));
    if (source === 'xinghai') return aggregateQuality(quality);
    return quality;
  }

  function stopScope(scope) {
    if (scope.cancelled) return;
    scope.cancelled = true;
    host.cancel(scope.id);
  }

  function stopOperation(state, timedOut) {
    if (timedOut) state.timedOut = true;
    else state.cancelled = true;
    for (const scope of state.scopes.values()) stopScope(scope);
  }

  function firstSuccess(tasks) {
    return new Promise(function collect(resolve, reject) {
      let remaining = tasks.length;
      const errors = [];
      if (!remaining) { reject(new SourceError('SOURCE_UNAVAILABLE', '当前没有可用音源')); return; }
      function failure(error) {
        errors.push(error);
        remaining--;
        if (!remaining) { const aggregate = new Error('全部音源失败'); aggregate.errors = errors; reject(aggregate); }
      }
      for (const task of tasks) task.then(resolve, failure);
    });
  }

  function consumeTasks(tasks) {
    const results = [];
    function completed() {}
    for (const task of tasks) results.push(task.then(completed, completed));
    return Promise.all(results);
  }

  async function runSource(definition, song, context) {
    requireActive(context);
    context.attempted.add(definition.id + ':' + effectiveQuality(definition.id, song.platform, song.quality));
    const local = Object.assign({}, context, {credentials: definition.values,
      device: 'qt-' + host.sha256(JSON.stringify(definition.values)).slice(0, 32)});
    try {
      const result = await handlers[definition.id](song, local);
      requireActive(context);
      return Object.assign(resolved(result, definition.id), {providerName: definition.name, quality: song.quality});
    } catch (error) {
      if (context.failures.length < 32) context.failures.push({source: definition.id, code: error.code || 'UPSTREAM_ERROR'});
      if (sourceFailures.has(error.code)) context.excluded.add(definition.id);
      throw error;
    }
  }

  async function raceSources(group, song, state) {
    const scope = {id: state.id + ':race' + (++state.raceCount), cancelled: false};
    state.scopes.set(scope.id, scope);
    const context = {state, scope, matches: state.matches, bitrates: state.bitrates,
      attempted: state.attempted, excluded: state.excluded, failures: state.failures};
    const tasks = [];
    for (const definition of group) tasks.push(runSource(definition, song, context));
    try { return await firstSuccess(tasks); }
    catch (error) {
      requireActive(context);
      if (song.source !== 'automatic') throw error.errors && error.errors[0] || error;
      return null;
    } finally {
      stopScope(scope);
      // 所有落选请求都已取消；消费其拒绝结果，避免悬挂 Promise 和未处理异常。
      await consumeTasks(tasks);
      state.scopes.delete(scope.id);
    }
  }

  async function resolveGroups(song, selected, state) {
    const groups = new Set();
    for (const definition of selected) groups.add(definition.group || 0);
    const groupIds = Array.from(groups);
    function compare(left, right) { return left - right; }
    groupIds.sort(compare);
    for (const quality of qualityCandidates(song)) {
      for (const groupId of groupIds) {
        const candidates = candidatesFor(selected, groupId, song.platform, quality, state);
        const result = await resolveChunks(candidates, Object.assign({}, song, {quality}), state);
        if (result) return Object.assign({protocolVersion: 1}, result);
      }
    }
    if (state.timedOut) throw new SourceError('RESOLVE_TIMEOUT', '音源解析超时');
    if (state.cancelled) throw new SourceError('RESOLVE_CANCELLED', '播放解析已取消');
    throw new SourceError('SOURCES_UNAVAILABLE', '当前音源均无法解析这首歌曲');
  }

  function candidatesFor(selected, groupId, platform, quality, state) {
    const candidates = [];
    for (const definition of selected) {
      const attemptKey = definition.id + ':' + effectiveQuality(definition.id, platform, quality);
      if ((definition.group || 0) === groupId && !state.excluded.has(definition.id) && !state.attempted.has(attemptKey)) {
        candidates.push(definition);
      }
    }
    return candidates;
  }

  async function resolveChunks(candidates, song, state) {
    // 源数增加时顺序分批，手机的单首歌并发仍然最多四个请求。
    for (let index = 0; index < candidates.length; index += 4) {
      if (state.timedOut) throw new SourceError('RESOLVE_TIMEOUT', '音源解析超时');
      if (state.cancelled) throw new SourceError('RESOLVE_CANCELLED', '播放解析已取消');
      const result = await raceSources(candidates.slice(index, index + 4), song, state);
      if (result) return result;
    }
    return null;
  }

  function resolved(body, providerId) {
    const data = body && body.data;
    const value = data && typeof data === 'object' ? data : body;
    const url = typeof data === 'string' ? data : value && (value.url || value.musicUrl || value.playUrl) || body && body.url;
    if (body && (body.encrypted || body.encryption === 'cenc') || value && (value.encrypted || value.encryption === 'cenc')) {
      throw new SourceError('ENCRYPTED_AUDIO', '上游返回加密音频');
    }
    const authority = typeof url === 'string' && /^https?:\/\/([^/?#]+)/i.exec(url);
    if (!authority || !authority[1] || authority[1].includes('@') || url.length > 8192 || url.includes('#') || /[\x00-\x20\x7f]/.test(url)) {
      throw new SourceError('INVALID_AUDIO_URL', '上游未返回有效音频地址');
    }
    const cleanPath = url.split('?')[0];
    const dot = cleanPath.lastIndexOf('.');
    const extension = dot > cleanPath.lastIndexOf('/') ? cleanPath.slice(dot + 1) : '';
    const format = String(value && value.format || extension).toLowerCase();
    if (['mgg', 'mflac', 'cenc'].includes(format)) throw new SourceError('ENCRYPTED_AUDIO', '上游返回加密音频');
    const rawHeaders = value && (value.playbackHeaders || value.headers) || body && (body.playbackHeaders || body.headers) || {};
    if (!rawHeaders || typeof rawHeaders !== 'object' || Array.isArray(rawHeaders) || Object.keys(rawHeaders).length > 16) {
      throw new SourceError('INVALID_HEADERS', '播放请求头无效');
    }
    const playbackHeaders = Object.create(null);
    for (const key of Object.keys(rawHeaders)) {
      const header = rawHeaders[key];
      if (!/^[A-Za-z0-9-]{1,64}$/.test(key) || typeof header !== 'string' || header.length > 4096 ||
          /[^\x20-\x7e]/.test(header) || ['host', 'content-length', 'connection', 'transfer-encoding'].includes(key.toLowerCase())) {
        throw new SourceError('INVALID_HEADERS', '播放请求头无效');
      }
      playbackHeaders[key] = header;
    }
    const result = {url, providerId, format: /^[a-z0-9]{1,12}$/.test(format) ? format : null, playbackHeaders};
    const expiry = value && value.expiresAt;
    if (expiry !== undefined && expiry !== null) {
      if (!Number.isInteger(expiry) || expiry <= host.now() || expiry > 8640000000000000) {
        throw new SourceError('EXPIRED_URL', '音频地址已过期');
      }
      result.expiresAt = expiry;
    }
    return result;
  }

  function validateDefinitions() {
    if (sources.length > 32) throw new SourceError('INVALID_SOURCE_CONFIG', '音源定义超过上限');
    const ids = new Set();
    for (const source of sources) {
      if (!source || typeof source.id !== 'string' || !validId.test(source.id) || source.id === 'automatic' || ids.has(source.id) ||
          !validText(source.name, 80) || !validText(source.description || '', 512, true) ||
          !validPlatforms(source.platforms) || !validPlatforms(source.experimentalPlatforms || [])) {
        throw new SourceError('INVALID_SOURCE_CONFIG', '音源定义无效');
      }
      ids.add(source.id);
      const group = source.group === undefined ? 0 : source.group;
      if (!Number.isInteger(group) || group < 0 || group > 31 ||
          !hasOwn(handlers, source.id) || typeof handlers[source.id] !== 'function') {
        throw new SourceError('INVALID_SOURCE_CONFIG', '音源分组或处理函数无效');
      }
      const fields = source.credentials || [];
      if (!Array.isArray(fields) || fields.length > 16) throw new SourceError('INVALID_SOURCE_CONFIG', '音源凭据字段超过上限');
      const keys = new Set();
      for (const field of fields) {
        if (!field || typeof field.key !== 'string' || !/^[A-Za-z][A-Za-z0-9_]{0,63}$/.test(field.key) || keys.has(field.key) ||
            !validText(field.label, 80) || !validPlatforms(field.requiredPlatforms)) throw new SourceError('INVALID_SOURCE_CONFIG', '音源凭据定义无效');
        keys.add(field.key);
      }
    }
  }

  function validPlatforms(values) {
    if (!Array.isArray(values) || values.length > 3 || new Set(values).size !== values.length) return false;
    for (const value of values) {
      if (!platforms.includes(value)) return false;
    }
    return true;
  }

  /** 返回本地包当前音源能力，不访问任何网络。SHIXIAOYANG，2026/11/21。 */
  function getCapabilities() {
    const result = [];
    for (const source of sources) {
      if (source.enabled === false) continue;
      const credentials = [];
      for (const field of source.credentials || []) credentials.push({key: field.key, label: field.label, requiredPlatforms: field.requiredPlatforms.slice()});
      result.push({id: source.id, name: source.name, description: source.description || '', platforms: source.platforms.slice(),
        experimentalPlatforms: (source.experimentalPlatforms || []).slice(), credentials});
    }
    return {protocolVersion: 1, revision, sources: result};
  }

  /** 本地解析一首歌；操作结束时释放其全部 HTTP/计时 scope。 */
  async function resolve(input, operationId) {
    if (disposed) throw new SourceError('RESOLVE_CANCELLED', '本地解析包已关闭');
    if (typeof operationId !== 'string' || !/^[A-Za-z0-9_]{1,80}$/.test(operationId)) {
      throw new SourceError('INVALID_OPERATION', '解析操作标识无效');
    }
    if (operations.size >= 4 || operations.has(operationId)) throw new SourceError('RESOLVE_BUSY', '本地解析繁忙，请稍后重试');
    const song = validateInput(input);
    const selected = eligibleSources(song, input);
    const state = {id: operationId, cancelled: false, timedOut: false, scopes: new Map(), raceCount: 0,
      matches: new Map(), bitrates: new Set(), attempted: new Set(), excluded: sourceSet(input.excludedSources), failures: []};
    const deadline = {id: operationId + ':deadline', cancelled: false};
    state.scopes.set(deadline.id, deadline);
    operations.set(operationId, state);
    function expired() { stopOperation(state, true); }
    function timerCancelled() {}
    try {
      const timer = host.delay(deadline.id, 19000);
      timer.then(expired, timerCancelled);
      return await resolveGroups(song, selected, state);
    }
    finally {
      stopOperation(state, false);
      state.scopes.clear();
      state.matches.clear();
      state.bitrates.clear();
      operations.delete(operationId);
    }
  }

  /** 切歌、切换用户或关闭请求时主动取消进行中的操作。 */
  function cancel(operationId) {
    const state = operations.get(operationId);
    if (state) stopOperation(state, false);
  }

  /** 释放本地包所有操作及有界令牌缓存，不能保留旧用户请求。 */
  function dispose() {
    disposed = true;
    for (const state of operations.values()) stopOperation(state, false);
    operations.clear();
    tokens.clear();
  }

  validateDefinitions();
  globalThis.KuzaiSources = Object.freeze({getCapabilities, resolve, cancel, dispose,
    allowedOrigins: Object.freeze(allowedOrigins.slice())});
})();
