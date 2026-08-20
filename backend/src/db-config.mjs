export function postgresConfig(env = process.env) {
  const config = {};
  const connectionString = String(env.DATABASE_URL || '').trim();

  if (connectionString) {
    config.connectionString = connectionString;
  } else {
    const fields = [
      ['host', 'PGHOST'],
      ['port', 'PGPORT'],
      ['database', 'PGDATABASE'],
      ['user', 'PGUSER'],
      ['password', 'PGPASSWORD'],
    ];
    for (const [key, name] of fields) {
      if (env[name] !== undefined && env[name] !== '') config[key] = env[name];
    }
  }

  config.ssl = env.DATABASE_SSL === 'true'
    ? { rejectUnauthorized: false }
    : false;
  return config;
}

export function hasPostgresConfig(env = process.env) {
  return Boolean(String(env.DATABASE_URL || '').trim() || String(env.PGHOST || '').trim());
}
