import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Pool } from 'pg';
import { mergeSnapshotPayload } from './sync-merge.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const port = Number(process.env.PORT || 8787);
const sessionDays = Math.max(1, Number(process.env.SESSION_DAYS || 30));
const maxBodyBytes = 2 * 1024 * 1024;
const allowedDomains = new Set(['favorites', 'history', 'settings', 'search_history']);
const loginAttempts = new Map();
const loginWindowMs = 15 * 60 * 1000;
const maxLoginAttempts = 5;
const fakePasswordSalt = Buffer.from('3dc351230a89056b12221ba8ee30e365', 'hex');
const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: process.env.DATABASE_SSL === 'true' ? { rejectUnauthorized: false } : false,
});

class ApiError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

function json(res, status, body) {
  const text = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
    'Referrer-Policy': 'no-referrer',
    'Content-Length': Buffer.byteLength(text),
  });
  res.end(text);
}

function noContent(res) {
  res.writeHead(204, { 'Cache-Control': 'no-store' });
  res.end();
}

function parseBearer(req) {
  const value = req.headers.authorization || '';
  return value.startsWith('Bearer ') ? value.slice(7).trim() : '';
}

function tokenHash(value) {
  return crypto.createHash('sha256').update(value).digest();
}

function randomToken() {
  return crypto.randomBytes(32).toString('base64url');
}

function normalizeUsername(value) {
  return String(value || '').trim().toLowerCase();
}

function loginAttemptKey(identity, username) {
  return `${identity}:${username}`;
}

function checkLoginRate(identity, username) {
  const key = loginAttemptKey(identity, username);
  const ipKey = `ip:${identity}`;
  const now = Date.now();
  const recent = (loginAttempts.get(key) || []).filter((time) => now - time < loginWindowMs);
  const recentForIp = (loginAttempts.get(ipKey) || []).filter((time) => now - time < loginWindowMs);
  if (recent.length >= maxLoginAttempts || recentForIp.length >= 30) {
    throw new ApiError(429, 'LOGIN_RATE_LIMITED', '登录尝试过多，请 15 分钟后再试');
  }
  if (recent.length) loginAttempts.set(key, recent);
  else loginAttempts.delete(key);
  if (recentForIp.length) loginAttempts.set(ipKey, recentForIp);
  else loginAttempts.delete(ipKey);
  if (loginAttempts.size > 10000) {
    for (const [candidate, times] of loginAttempts) {
      if (!times.some((time) => now - time < loginWindowMs)) loginAttempts.delete(candidate);
    }
  }
}

function recordLoginFailure(identity, username) {
  const key = loginAttemptKey(identity, username);
  const values = loginAttempts.get(key) || [];
  values.push(Date.now());
  loginAttempts.set(key, values);
  const ipKey = `ip:${identity}`;
  const ipValues = loginAttempts.get(ipKey) || [];
  ipValues.push(Date.now());
  loginAttempts.set(ipKey, ipValues);
}

function clearLoginFailures(identity, username) {
  loginAttempts.delete(loginAttemptKey(identity, username));
  loginAttempts.delete(`ip:${identity}`);
}

function passwordHash(password, salt) {
  return new Promise((resolve, reject) => {
    crypto.scrypt(password, salt, 64, { N: 16384, r: 8, p: 1 }, (error, result) => {
      if (error) reject(error);
      else resolve(result);
    });
  });
}

async function readJson(req) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > maxBodyBytes) throw new ApiError(413, 'BODY_TOO_LARGE', '请求内容不能超过 2 MB');
    chunks.push(chunk);
  }
  if (size === 0) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    throw new ApiError(400, 'INVALID_JSON', '请求不是有效的 JSON');
  }
}

function userView(row) {
  return {
    id: row.id,
    username: row.username,
    role: row.role,
    status: row.status,
    statusReason: row.status_reason,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    lastLoginAt: row.last_login_at,
  };
}

async function requireUser(req, { admin = false } = {}) {
  const raw = parseBearer(req);
  if (!raw || raw.length < 32) throw new ApiError(401, 'UNAUTHORIZED', '请先登录');
  const result = await pool.query(
    `SELECT s.id AS session_id, s.revoked_at AS session_revoked_at,
            s.expires_at AS session_expires_at, u.*
       FROM user_sessions s
       JOIN app_users u ON u.id = s.user_id
      WHERE s.token_hash = $1`,
    [tokenHash(raw)],
  );
  if (result.rowCount === 0) throw new ApiError(401, 'UNAUTHORIZED', '登录已过期，请重新登录');
  const row = result.rows[0];
  if (row.status !== 'active') {
    throw new ApiError(403, 'USER_DISABLED', row.status_reason || '当前账号不可用');
  }
  if (row.session_revoked_at || new Date(row.session_expires_at) <= new Date()) {
    throw new ApiError(401, 'UNAUTHORIZED', '登录已过期，请重新登录');
  }
  if (admin && row.role !== 'admin') throw new ApiError(403, 'ADMIN_REQUIRED', '需要管理员权限');
  return row;
}

async function audit(actorId, action, targetId = null, metadata = {}) {
  await pool.query(
    `INSERT INTO audit_logs(actor_user_id, target_user_id, action, metadata)
     VALUES ($1, $2, $3, $4::jsonb)`,
    [actorId, targetId, action, JSON.stringify(metadata)],
  );
}

function sameJson(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

async function login(body, identity) {
  const username = String(body.username || '').trim();
  const normalized = normalizeUsername(username);
  const password = String(body.password || '');
  if (!normalized || normalized.length > 64 || password.length < 1 || password.length > 256) {
    throw new ApiError(400, 'INVALID_CREDENTIALS', '请输入有效的用户名和密码');
  }
  checkLoginRate(identity, normalized);
  const result = await pool.query('SELECT * FROM app_users WHERE username_normalized = $1', [normalized]);
  if (result.rowCount === 0) {
    await passwordHash(password, fakePasswordSalt);
    recordLoginFailure(identity, normalized);
    throw new ApiError(401, 'INVALID_CREDENTIALS', '用户名或密码错误');
  }
  const user = result.rows[0];
  const candidate = await passwordHash(password, user.password_salt);
  if (!crypto.timingSafeEqual(candidate, user.password_hash)) {
    recordLoginFailure(identity, normalized);
    throw new ApiError(401, 'INVALID_CREDENTIALS', '用户名或密码错误');
  }
  if (user.status !== 'active') {
    throw new ApiError(403, 'USER_DISABLED', user.status_reason || '当前账号尚未启用');
  }
  const clientDeviceId = String(body.deviceId || '').trim().slice(0, 128) || crypto.randomUUID();
  const deviceName = String(body.deviceName || '未命名设备').trim().slice(0, 120) || '未命名设备';
  const platform = String(body.platform || 'unknown').trim().slice(0, 32) || 'unknown';
  const appVersion = String(body.appVersion || '').trim().slice(0, 32) || null;
  clearLoginFailures(identity, normalized);
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const device = await client.query(
      `INSERT INTO user_devices(user_id, client_device_id, name, platform, app_version)
       VALUES ($1, $2, $3, $4, $5)
       ON CONFLICT (user_id, client_device_id) DO UPDATE SET
         name = EXCLUDED.name,
         platform = EXCLUDED.platform,
         app_version = EXCLUDED.app_version,
         last_seen_at = now(),
         revoked_at = NULL
       RETURNING id`,
      [user.id, clientDeviceId, deviceName, platform, appVersion],
    );
    const token = randomToken();
    const expiresAt = new Date(Date.now() + sessionDays * 86400000);
    await client.query(
      `INSERT INTO user_sessions(user_id, device_id, token_hash, expires_at)
       VALUES ($1, $2, $3, $4)`,
      [user.id, device.rows[0].id, tokenHash(token), expiresAt],
    );
    await client.query('UPDATE app_users SET last_login_at = now() WHERE id = $1', [user.id]);
    await client.query(
      `INSERT INTO audit_logs(actor_user_id, target_user_id, action, metadata)
       VALUES ($1, $1, 'login', $2::jsonb)`,
      [user.id, JSON.stringify({ platform, deviceName })],
    );
    await client.query('COMMIT');
    return { token, expiresAt, user: userView(user), deviceId: clientDeviceId };
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}

async function pushSync(user, body) {
  const domain = String(body.domain || '');
  if (!allowedDomains.has(domain)) throw new ApiError(400, 'INVALID_DOMAIN', '不支持的同步数据类型');
  if (!body.payload || typeof body.payload !== 'object' || Array.isArray(body.payload)) {
    throw new ApiError(400, 'INVALID_PAYLOAD', '同步内容格式错误');
  }
  if (
    body.payload.kind !== 'snapshot' ||
    !Number.isSafeInteger(Number(body.payload.updatedAt)) ||
    Number(body.payload.updatedAt) <= 0
  ) {
    throw new ApiError(400, 'INVALID_PAYLOAD', '同步快照缺少有效的更新时间');
  }
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query(
      `SELECT pg_advisory_xact_lock(hashtext($1 || ':' || $2))`,
      [user.id, domain],
    );
    const current = await client.query(
      `SELECT revision, payload FROM sync_documents WHERE user_id = $1 AND domain = $2 FOR UPDATE`,
      [user.id, domain],
    );
    const oldRevision = current.rowCount ? Number(current.rows[0].revision) : 0;
    const oldPayload = current.rowCount ? current.rows[0].payload : {};
    const baseRevision = Number(body.baseRevision || 0);
    const basePayload = body.basePayload && typeof body.basePayload === 'object'
      ? body.basePayload
      : { kind: 'snapshot', schema: 1, values: {} };
    const merged = mergeSnapshotPayload(
      oldPayload,
      body.payload,
      basePayload,
      baseRevision,
      oldRevision,
    );
    if (sameJson(oldPayload, merged)) {
      const latestChange = await client.query(
        `SELECT COALESCE(max(cursor), 0) AS cursor
           FROM sync_changes WHERE user_id = $1 AND domain = $2`,
        [user.id, domain],
      );
      await client.query('COMMIT');
      return {
        domain,
        revision: oldRevision,
        payload: oldPayload,
        cursor: Number(latestChange.rows[0].cursor),
      };
    }
    const revision = oldRevision + 1;
    await client.query(
      `INSERT INTO sync_documents(user_id, domain, revision, payload)
       VALUES ($1, $2, $3, $4::jsonb)
       ON CONFLICT (user_id, domain) DO UPDATE SET
         revision = EXCLUDED.revision,
         payload = EXCLUDED.payload,
         updated_at = now()`,
      [user.id, domain, revision, JSON.stringify(merged)],
    );
    const change = await client.query(
      `INSERT INTO sync_changes(user_id, domain, revision, payload)
       VALUES ($1, $2, $3, $4::jsonb)
       RETURNING cursor`,
      [user.id, domain, revision, JSON.stringify(merged)],
    );
    await client.query(
      `DELETE FROM sync_changes
        WHERE user_id = $1 AND domain = $2 AND cursor <> $3`,
      [user.id, domain, change.rows[0].cursor],
    );
    await client.query('COMMIT');
    return { domain, revision, payload: merged, cursor: Number(change.rows[0].cursor) };
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}

async function pullSync(user, cursor) {
  const parsed = Number(cursor || 0);
  if (!Number.isSafeInteger(parsed) || parsed < 0) throw new ApiError(400, 'INVALID_CURSOR', '同步游标无效');
  const result = await pool.query(
    `SELECT cursor, domain, revision, payload, changed_at
       FROM sync_changes
      WHERE user_id = $1 AND cursor > $2
      ORDER BY cursor ASC
      LIMIT 101`,
    [user.id, parsed],
  );
  const hasMore = result.rows.length > 100;
  const rows = result.rows.slice(0, 100);
  const nextCursor = rows.length ? Number(rows[rows.length - 1].cursor) : parsed;
  return {
    cursor: nextCursor,
    hasMore,
    changes: rows.map((row) => ({
      cursor: Number(row.cursor),
      domain: row.domain,
      revision: Number(row.revision),
      payload: row.payload,
      changedAt: row.changed_at,
    })),
  };
}

async function listUsers(url) {
  const search = String(url.searchParams.get('q') || '').trim();
  const status = String(url.searchParams.get('status') || '').trim();
  const args = [];
  const where = [];
  if (search) {
    args.push(`%${search.toLowerCase()}%`);
    where.push(`username_normalized LIKE $${args.length}`);
  }
  if (['pending', 'active', 'disabled', 'deleted'].includes(status)) {
    args.push(status);
    where.push(`status = $${args.length}`);
  }
  const result = await pool.query(
    `SELECT id, username, role, status, status_reason, created_at, updated_at, last_login_at
       FROM app_users ${where.length ? `WHERE ${where.join(' AND ')}` : ''}
      ORDER BY created_at DESC LIMIT 200`,
    args,
  );
  return result.rows.map(userView);
}

async function createUser(actor, body) {
  const username = String(body.username || '').trim();
  const normalized = normalizeUsername(username);
  const password = String(body.password || '');
  const status = body.status === 'active' ? 'active' : 'pending';
  if (!/^[\w.-]{3,64}$/u.test(username)) throw new ApiError(400, 'INVALID_USERNAME', '用户名需为 3-64 位字母、数字、下划线、点或短横线');
  if (password.length < 10 || password.length > 256) {
    throw new ApiError(400, 'WEAK_PASSWORD', '密码长度需为 10-256 位');
  }
  const salt = crypto.randomBytes(16);
  const hash = await passwordHash(password, salt);
  try {
    const result = await pool.query(
      `INSERT INTO app_users(username, username_normalized, password_salt, password_hash, status)
       VALUES ($1, $2, $3, $4, $5)
       RETURNING id, username, role, status, status_reason, created_at, updated_at, last_login_at`,
      [username, normalized, salt, hash, status],
    );
    await audit(actor.id, 'create_user', result.rows[0].id, { status });
    return userView(result.rows[0]);
  } catch (error) {
    if (error.code === '23505') throw new ApiError(409, 'USERNAME_EXISTS', '用户名已存在');
    throw error;
  }
}

async function changeUserStatus(actor, userId, body) {
  const status = String(body.status || '');
  if (!['pending', 'active', 'disabled', 'deleted'].includes(status)) throw new ApiError(400, 'INVALID_STATUS', '用户状态无效');
  const reason = String(body.reason || '').trim().slice(0, 500) || null;
  if (actor.id === userId && (status === 'disabled' || status === 'deleted')) {
    throw new ApiError(400, 'CANNOT_DISABLE_SELF', '不能禁用或删除当前管理员账号');
  }
  const result = await pool.query(
    `UPDATE app_users SET status = $2, status_reason = $3
      WHERE id = $1
      RETURNING id, username, role, status, status_reason, created_at, updated_at, last_login_at`,
    [userId, status, status === 'disabled' ? reason : null],
  );
  if (!result.rowCount) throw new ApiError(404, 'USER_NOT_FOUND', '用户不存在');
  if (status === 'disabled' || status === 'deleted') {
    await pool.query('UPDATE user_sessions SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL', [userId]);
  }
  await audit(actor.id, `set_user_status:${status}`, userId, { reason });
  return userView(result.rows[0]);
}

async function resetPassword(actor, userId, body) {
  const password = String(body.password || '');
  if (password.length < 10 || password.length > 256) {
    throw new ApiError(400, 'WEAK_PASSWORD', '密码长度需为 10-256 位');
  }
  const salt = crypto.randomBytes(16);
  const hash = await passwordHash(password, salt);
  const result = await pool.query(
    `UPDATE app_users SET password_salt = $2, password_hash = $3 WHERE id = $1 RETURNING id`,
    [userId, salt, hash],
  );
  if (!result.rowCount) throw new ApiError(404, 'USER_NOT_FOUND', '用户不存在');
  await pool.query('UPDATE user_sessions SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL', [userId]);
  await audit(actor.id, 'reset_password', userId);
}

async function handleApi(req, res, url) {
  const method = req.method || 'GET';
  if (method === 'POST' && url.pathname === '/api/auth/login') {
    json(res, 200, await login(await readJson(req), req.socket.remoteAddress || 'unknown'));
    return;
  }
  if (method === 'GET' && url.pathname === '/api/me') {
    const user = await requireUser(req);
    json(res, 200, { user: userView(user) });
    return;
  }
  if (method === 'POST' && url.pathname === '/api/auth/logout') {
    const raw = parseBearer(req);
    if (raw) await pool.query('UPDATE user_sessions SET revoked_at = now() WHERE token_hash = $1', [tokenHash(raw)]);
    noContent(res);
    return;
  }
  if (method === 'GET' && url.pathname === '/api/sync') {
    const user = await requireUser(req);
    json(res, 200, await pullSync(user, url.searchParams.get('cursor')));
    return;
  }
  if (method === 'POST' && url.pathname === '/api/sync') {
    const user = await requireUser(req);
    json(res, 200, await pushSync(user, await readJson(req)));
    return;
  }
  if (url.pathname.startsWith('/api/admin/')) {
    const actor = await requireUser(req, { admin: true });
    if (method === 'GET' && url.pathname === '/api/admin/users') {
      json(res, 200, { users: await listUsers(url) });
      return;
    }
    if (method === 'POST' && url.pathname === '/api/admin/users') {
      json(res, 201, { user: await createUser(actor, await readJson(req)) });
      return;
    }
    const userMatch = url.pathname.match(/^\/api\/admin\/users\/([^/]+)\/([^/]+)$/u);
    if (userMatch && !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu.test(userMatch[1])) {
      throw new ApiError(400, 'INVALID_USER_ID', '用户 ID 无效');
    }
    if (userMatch && method === 'PATCH' && userMatch[2] === 'status') {
      json(res, 200, { user: await changeUserStatus(actor, userMatch[1], await readJson(req)) });
      return;
    }
    if (userMatch && method === 'POST' && userMatch[2] === 'reset-password') {
      await resetPassword(actor, userMatch[1], await readJson(req));
      noContent(res);
      return;
    }
    if (method === 'GET' && url.pathname === '/api/admin/audit') {
      const rows = await pool.query(
        `SELECT a.id, a.action, a.metadata, a.created_at, au.username AS actor, tu.username AS target
           FROM audit_logs a
           LEFT JOIN app_users au ON au.id = a.actor_user_id
           LEFT JOIN app_users tu ON tu.id = a.target_user_id
          ORDER BY a.created_at DESC LIMIT 200`,
      );
      json(res, 200, { logs: rows.rows });
      return;
    }
  }
  throw new ApiError(404, 'NOT_FOUND', '接口不存在');
}

async function serveStatic(req, res, url) {
  const requested = url.pathname === '/' ? '/index.html' : url.pathname;
  const file = path.resolve(path.join(root, 'public', requested.replace(/^\/+/, '')));
  if (!file.startsWith(path.resolve(path.join(root, 'public')))) throw new ApiError(404, 'NOT_FOUND', '页面不存在');
  try {
    const content = await fs.readFile(file);
    const type = file.endsWith('.html') ? 'text/html; charset=utf-8' : 'text/plain; charset=utf-8';
    res.writeHead(200, {
      'Content-Type': type,
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
      'X-Frame-Options': 'DENY',
      'Referrer-Policy': 'no-referrer',
    });
    res.end(content);
  } catch {
    throw new ApiError(404, 'NOT_FOUND', '页面不存在');
  }
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url || '/', `http://${req.headers.host || '127.0.0.1'}`);
  try {
    if (url.pathname === '/healthz') {
      await pool.query('SELECT 1');
      json(res, 200, { ok: true, service: 'kuzai-music-account-server' });
      return;
    }
    if (url.pathname.startsWith('/api/')) await handleApi(req, res, url);
    else await serveStatic(req, res, url);
  } catch (error) {
    const status = error instanceof ApiError ? error.status : 500;
    if (!(error instanceof ApiError)) console.error(error);
    json(res, status, {
      error: error instanceof ApiError ? error.code : 'INTERNAL_ERROR',
      message: error instanceof ApiError ? error.message : '服务器内部错误',
    });
  }
});

server.listen(port, () => console.log(`库仔音乐账号服务已启动: http://127.0.0.1:${port}`));

const shutdown = async () => {
  server.close();
  await pool.end();
  process.exit(0);
};
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
