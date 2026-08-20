import assert from 'node:assert/strict';
import test from 'node:test';

import { hasPostgresConfig, postgresConfig } from '../src/db-config.mjs';

test('DATABASE_URL takes precedence over individual PostgreSQL variables', () => {
  assert.deepEqual(
    postgresConfig({
      DATABASE_URL: 'postgres://url-user:url-pass@db.example/music',
      PGHOST: 'ignored.example',
      DATABASE_SSL: 'true',
    }),
    {
      connectionString: 'postgres://url-user:url-pass@db.example/music',
      ssl: { rejectUnauthorized: false },
    },
  );
});

test('standard PG variables form a connection when DATABASE_URL is absent', () => {
  assert.deepEqual(
    postgresConfig({
      PGHOST: 'postgres',
      PGPORT: '5432',
      PGDATABASE: 'kuzai_music',
      PGUSER: 'kuzai',
      PGPASSWORD: 'secret',
      DATABASE_SSL: 'false',
    }),
    {
      host: 'postgres',
      port: '5432',
      database: 'kuzai_music',
      user: 'kuzai',
      password: 'secret',
      ssl: false,
    },
  );
});

test('PostgreSQL configuration detection ignores empty values', () => {
  assert.equal(hasPostgresConfig({ DATABASE_URL: '  ', PGHOST: '' }), false);
  assert.equal(hasPostgresConfig({ PGHOST: 'postgres' }), true);
});
