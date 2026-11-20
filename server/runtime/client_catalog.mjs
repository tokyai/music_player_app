import crypto from 'node:crypto';
import {SourceError} from './network.mjs';

// 海外出口受到限制时，只把公共目录的网络传输交给设备，协议和解析仍由服务端维护。
// SHIXIAOYANG，2026/11/20。
const pending = new Map();
const maxResponseBytes = 512 * 1024;

/** 创建有界、一次性的公共目录请求，回调中不保留原 HTTP 请求的取消信号。 */
export function clientCatalog(request,transform) {
  const now = Date.now();
  for (const [id, item] of pending) {
    if (item.expires <= now) pending.delete(id);
  }
  if (pending.size >= 16) pending.delete(pending.keys().next().value);
  const id = crypto.randomBytes(16).toString('hex');
  pending.set(id, {transform, expires: now + 45000});
  return {clientRequest: {
    id,
    url: String(request.url),
    method: request.body === undefined ? 'GET' : 'POST',
    headers: request.headers || {},
    body: request.body,
    maxBytes: maxResponseBytes,
  }};
}

/** 消费请求回执；传输失败、超时和无效内容不会污染其他请求或服务器目录缓存。 */
export async function completeClientCatalog(input,signal) {
  if (!input || typeof input.id !== 'string' || !/^[a-f0-9]{32}$/.test(input.id) ||
      typeof input.bodyBase64 !== 'string' || input.bodyBase64.length > 704 * 1024) {
    throw new SourceError('INVALID_INPUT', '目录请求回执无效');
  }

  // 失败和取消也消费编号，防止同一回执重复执行目录转换或缓存写入。
  const item = pending.get(input.id);
  pending.delete(input.id);
  if (!item || item.expires <= Date.now()) {
    throw new SourceError('CLIENT_REQUEST_EXPIRED', '目录请求已过期，请重试');
  }
  if (signal?.aborted) throw new SourceError('REQUEST_CANCELLED', '请求已取消');
  if (!Number.isInteger(input.status) || input.status < 200 || input.status >= 300) {
    throw new SourceError('CLIENT_REQUEST_FAILED', '设备目录请求失败');
  }
  const bytes = Buffer.from(input.bodyBase64, 'base64');
  if (bytes.length > maxResponseBytes || bytes.toString('base64') !== input.bodyBase64) {
    throw new SourceError('CLIENT_RESPONSE_INVALID', '目录返回内容或大小无效');
  }
  let body;
  try {
    body = JSON.parse(bytes.toString('utf8'));
  } catch {
    throw new SourceError('CLIENT_RESPONSE_INVALID', '目录返回内容无效');
  }
  return item.transform(body, signal);
}
