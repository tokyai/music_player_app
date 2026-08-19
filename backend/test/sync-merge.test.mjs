import assert from 'node:assert/strict';
import test from 'node:test';

import { mergeSnapshotPayload } from '../src/sync-merge.mjs';

const song = (id, name = id) => ({ platform: 'qq', id, name });
const snapshot = (values) => ({
  kind: 'snapshot',
  schema: 1,
  updatedAt: 1,
  values,
});

test('concurrent favorite addition and deletion are both preserved', () => {
  const base = snapshot({ favorites: JSON.stringify([song('a'), song('b')]) });
  const cloud = snapshot({
    favorites: JSON.stringify([song('a'), song('b'), song('x')]),
  });
  const local = snapshot({ favorites: JSON.stringify([song('a')]) });

  const merged = mergeSnapshotPayload(cloud, local, base, 1, 2);
  const favorites = JSON.parse(merged.values.favorites);

  assert.deepEqual(
    favorites.map((item) => item.id).sort(),
    ['a', 'x'],
  );
});

test('same base revision accepts an authoritative clear', () => {
  const base = snapshot({ favorites: JSON.stringify([song('a')]) });
  const local = snapshot({ favorites: JSON.stringify([]) });

  const merged = mergeSnapshotPayload(base, local, base, 4, 4);

  assert.deepEqual(JSON.parse(merged.values.favorites), []);
});

test('history merge keeps the newest local position and concurrent cloud item', () => {
  const history = (id, playedAtMs, positionMs) => ({
    song: song(id),
    playedAtMs,
    positionMs,
  });
  const base = snapshot({
    playback_history_v1: JSON.stringify([history('a', 10, 100)]),
  });
  const cloud = snapshot({
    playback_history_v1: JSON.stringify([
      history('a', 10, 100),
      history('b', 20, 200),
    ]),
  });
  const local = snapshot({
    playback_history_v1: JSON.stringify([history('a', 30, 300)]),
  });

  const merged = mergeSnapshotPayload(cloud, local, base, 1, 2);
  const values = JSON.parse(merged.values.playback_history_v1);

  assert.deepEqual(values.map((item) => item.song.id), ['a', 'b']);
  assert.equal(values[0].positionMs, 300);
});
