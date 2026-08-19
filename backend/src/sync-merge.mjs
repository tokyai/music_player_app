function jsonEqual(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function listIdentity(item, nestedSong = false) {
  const value = nestedSong && item?.song && typeof item.song === 'object'
    ? item.song
    : item;
  if (!value || typeof value !== 'object') return '';
  const platform = String(value.platform || '');
  const id = String(value.id || '');
  const cid = nestedSong ? String(value.bilibiliCid || '') : '';
  return platform && id ? `${platform}:${id}:${cid}` : '';
}

function mergeJsonListValue(baseRaw, serverRaw, clientRaw, nestedSong = false) {
  const parse = (raw) => {
    if (typeof raw !== 'string') return [];
    try {
      const decoded = JSON.parse(raw);
      return Array.isArray(decoded) ? decoded : [];
    } catch {
      return [];
    }
  };
  const toMap = (items) => new Map(
    items
      .map((item) => [listIdentity(item, nestedSong), item])
      .filter(([key]) => key),
  );
  const base = toMap(parse(baseRaw));
  const server = toMap(parse(serverRaw));
  const client = toMap(parse(clientRaw));
  const result = new Map();
  const keys = new Set([...base.keys(), ...server.keys(), ...client.keys()]);
  for (const key of keys) {
    const before = base.get(key);
    const cloud = server.get(key);
    const local = client.get(key);
    let chosen;
    if (jsonEqual(local, before)) chosen = cloud;
    else if (jsonEqual(cloud, before)) chosen = local;
    else chosen = local;
    if (chosen !== undefined) result.set(key, chosen);
  }
  let values = [...result.values()];
  if (nestedSong) {
    values.sort((a, b) => Number(b.playedAtMs || 0) - Number(a.playedAtMs || 0));
    values = values.slice(0, 100);
  }
  return JSON.stringify(values);
}

function mergeSnapshot(base, server, client) {
  const baseValues = base?.values && typeof base.values === 'object' ? base.values : {};
  const serverValues = server?.values && typeof server.values === 'object' ? server.values : {};
  const clientValues = client?.values && typeof client.values === 'object' ? client.values : {};
  const values = {};
  const keys = new Set([
    ...Object.keys(baseValues),
    ...Object.keys(serverValues),
    ...Object.keys(clientValues),
  ]);
  for (const key of keys) {
    const before = baseValues[key];
    const cloud = serverValues[key];
    const local = clientValues[key];
    let chosen;
    if (jsonEqual(local, before)) chosen = cloud;
    else if (jsonEqual(cloud, before)) chosen = local;
    else if (key === 'favorites' || key === 'favorite_playlists') {
      chosen = mergeJsonListValue(before, cloud, local);
    } else if (key === 'playback_history_v1') {
      chosen = mergeJsonListValue(before, cloud, local, true);
    } else if (
      key === 'search_history' &&
      Array.isArray(local) &&
      Array.isArray(cloud)
    ) {
      chosen = [...new Set([...local, ...cloud])].slice(0, 20);
    } else {
      chosen = local;
    }
    if (chosen !== undefined) values[key] = chosen;
  }
  return {
    kind: 'snapshot',
    schema: 1,
    updatedAt: Date.now(),
    values,
  };
}

export function mergeSnapshotPayload(
  current,
  incoming,
  base,
  baseRevision,
  currentRevision,
) {
  if (baseRevision === currentRevision) {
    return { ...incoming, updatedAt: Date.now() };
  }
  return mergeSnapshot(base, current, incoming);
}
