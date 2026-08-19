import crypto from 'node:crypto';
import { Pool } from 'pg';

const username = process.argv[2] || 'admin';
const password = process.argv[3];
if (!password || password.length < 10 || password.length > 256) {
  console.error('用法: npm run create-admin -- <用户名> <10-256位密码>');
  process.exit(1);
}
if (!/^[\w.-]{3,64}$/u.test(username)) {
  console.error('用户名需为 3-64 位字母、数字、下划线、点或短横线');
  process.exit(1);
}
if (!process.env.DATABASE_URL && !process.env.PGHOST) {
  console.error('请先设置 DATABASE_URL 或 PostgreSQL 的 PGHOST/PGUSER/PGPASSWORD/PGDATABASE');
  process.exit(1);
}

const salt = crypto.randomBytes(16);
const hash = await new Promise((resolve, reject) => {
  crypto.scrypt(password, salt, 64, { N: 16384, r: 8, p: 1 }, (error, result) => {
    if (error) reject(error);
    else resolve(result);
  });
});

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: process.env.DATABASE_SSL === 'true' ? { rejectUnauthorized: false } : false,
});
try {
  await pool.query(
    `INSERT INTO app_users(username, username_normalized, password_salt, password_hash, role, status)
     VALUES ($1, lower(trim($1)), $2, $3, 'admin', 'active')
     ON CONFLICT (username_normalized) DO UPDATE SET
       password_salt = EXCLUDED.password_salt,
       password_hash = EXCLUDED.password_hash,
       role = 'admin',
       status = 'active',
       status_reason = NULL`,
    [username, salt, hash],
  );
  console.log(`管理员 ${username} 已创建或更新`);
} finally {
  await pool.end();
}
