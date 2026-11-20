/** 有界的固定上游请求。SHIXIAOYANG，2026/11/20。 */
export class SourceError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

const upstreamHosts = new Set([
  'musicserver.haitangw.cc', 'qt.haitangw.net', '103.79.184.97',
  'yy1.zddyr.top', 'music-api.gdstudio.xyz', 'api.chksz.com',
]);
const maxJsonResponseBytes = 512 * 1024;

/** 拼接已定义的上游参数，不接受客户端指定的请求地址。 */
export function query(base, params) {
  const url = new URL(base);
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined && value !== null && value !== '') {
      url.searchParams.set(key, String(value));
    }
  }
  return url;
}

/** 请求固定上游 JSON；取消、超时和体积上限均会释放响应流。 */
export async function fetchJson(url, {body, headers = {}, signal, timeout = 6500, maxBytes = maxJsonResponseBytes} = {}) {
  // 此服务只获取地址和有限候选，单源扩大响应上限会放大八首并发时的内存占用。
  if (!Number.isInteger(maxBytes) || maxBytes <= 0 || maxBytes > maxJsonResponseBytes) {
    throw new SourceError('INVALID_RESPONSE_LIMIT', '上游响应上限无效');
  }
  const target = new URL(url);
  if (!upstreamHosts.has(target.hostname) || target.username || target.password ||
      target.hash || !['http:', 'https:'].includes(target.protocol) ||
      (target.port && !['80', '443'].includes(target.port))) {
    throw new SourceError('INVALID_UPSTREAM', '上游接口地址未获允许');
  }
  const controller = new AbortController();
  const cancel = () => controller.abort();
  signal?.addEventListener('abort', cancel, {once: true});
  if (signal?.aborted) cancel();
  const timer = setTimeout(cancel, timeout);
  let reader;
  try {
    const response = await fetch(target, {
      method: body === undefined ? 'GET' : 'POST',
      headers: {'Accept': 'application/json', 'User-Agent': 'LX-Music-Mobile',
        ...(body === undefined ? {} : {'Content-Type': 'application/json'}), ...headers},
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: controller.signal, redirect: 'error',
    });
    if (!response.body) throw new SourceError('EMPTY_RESPONSE', '上游响应为空');
    reader = response.body.getReader();
    const pieces = [];
    let length = 0;
    while (true) {
      const part = await reader.read();
      if (part.done) break;
      length += part.value.length;
      if (length > maxBytes) {
        throw new SourceError('RESPONSE_TOO_LARGE', '上游响应过大');
      }
      pieces.push(Buffer.from(part.value));
    }
    const text = Buffer.concat(pieces, length).toString('utf8');
    let data;
    try { data = JSON.parse(text); }
    catch { throw new SourceError('UPSTREAM_INVALID_JSON', '上游返回非 JSON 内容'); }
    return {status: response.status, data};
  } catch (error) {
    if (error instanceof SourceError) throw error;
    if (signal?.aborted) throw new SourceError('RESOLVE_CANCELLED', '播放解析已取消');
    const code = controller.signal.aborted ? 'UPSTREAM_TIMEOUT' : 'UPSTREAM_NETWORK';
    throw new SourceError(code, '上游网络请求失败');
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener('abort', cancel);
    // 不保留响应或复制整份媒体内容；取消失败只影响已关闭的网络流。
    if (reader) await reader.cancel().catch(() => {});
    controller.abort();
  }
}

/** 统一解析结果，拒绝加密格式和不安全的播放请求头。 */
export function resolved(body, providerId) {
  const data = body?.data;
  const value = data && typeof data === 'object' ? data : body;
  const url = typeof data === 'string' ? data :
    (value?.url || body?.url || value?.musicUrl || value?.playUrl);
  if (body?.encrypted || value?.encrypted || body?.encryption === 'cenc' ||
      value?.encryption === 'cenc') {
    throw new SourceError('ENCRYPTED_AUDIO', '上游返回加密音频');
  }
  if (typeof url !== 'string' || url.length > 8192) {
    throw new SourceError('EMPTY_URL', '上游未返回有效音频地址');
  }
  let parsed;
  try { parsed = new URL(url); }
  catch { throw new SourceError('INVALID_AUDIO_URL', '音频地址无效'); }
  if (!['http:', 'https:'].includes(parsed.protocol) || parsed.username ||
      parsed.password || parsed.hash) {
    throw new SourceError('INVALID_AUDIO_URL', '音频地址协议无效');
  }
  const format = String(value?.format || parsed.pathname.split('.').at(-1) || '').toLowerCase();
  if (['mgg', 'mflac', 'cenc'].includes(format)) {
    throw new SourceError('ENCRYPTED_AUDIO', '上游返回加密音频');
  }
  const rawHeaders = value?.playbackHeaders || value?.headers || body?.playbackHeaders || body?.headers || {};
  if (!rawHeaders || typeof rawHeaders !== 'object' || Array.isArray(rawHeaders) ||
      Object.keys(rawHeaders).length > 16) {
    throw new SourceError('INVALID_HEADERS', '播放请求头无效');
  }
  const playbackHeaders = {};
  for (const [key, headerValue] of Object.entries(rawHeaders)) {
    if (!/^[A-Za-z0-9-]{1,64}$/.test(key) || typeof headerValue !== 'string' ||
        headerValue.length > 4096 || /[^\x20-\x7e]/.test(headerValue) ||
        ['host', 'content-length', 'connection', 'transfer-encoding'].includes(key.toLowerCase())) {
      throw new SourceError('INVALID_HEADERS', '播放请求头无效');
    }
    playbackHeaders[key] = headerValue;
  }
  return {url, providerId, format: /^[a-z0-9]{1,12}$/.test(format) ? format : null, playbackHeaders};
}
