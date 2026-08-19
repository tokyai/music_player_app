import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'account_service.dart';
import 'user_profile_store.dart';

class AccountSyncService {
  final AccountService account;

  const AccountSyncService(this.account);

  String _cursorKey(String userId) => '_account_sync_cursor_$userId';
  String _migratedKey(String userId) => '_account_sync_migrated_$userId';
  String _baseKey(String userId, String domain) =>
      '_account_sync_base_${userId}_$domain';

  Future<Set<String>> bootstrap() async {
    final user = account.user;
    if (user == null) return const {};
    final prefs = await SharedPreferences.getInstance();
    final firstMigration = !(prefs.getBool(_migratedKey(user.id)) ?? false);
    if (!firstMigration) {
      final locallyChanged = _locallyChangedDomains(prefs, user.id);
      if (locallyChanged.isNotEmpty) await syncDomains(locallyChanged);
    }
    var cursor = prefs.getInt(_cursorKey(user.id)) ?? 0;
    final latest = <String, Map<String, dynamic>>{};
    var hasMore = false;
    do {
      final response = await account.request(
        'GET',
        '/sync',
        authenticated: true,
        query: {'cursor': '$cursor'},
      );
      final rawChanges = response['changes'];
      if (rawChanges is List) {
        for (final raw in rawChanges) {
          if (raw is! Map) continue;
          final change = Map<String, dynamic>.from(raw);
          final domain = change['domain']?.toString() ?? '';
          final payload = change['payload'];
          if (payload is Map) {
            latest[domain] = change;
          }
        }
      }
      final nextCursor = response['cursor'];
      if (nextCursor is num) cursor = nextCursor.toInt();
      hasMore = response['hasMore'] == true;
    } while (hasMore);

    for (final entry in latest.entries) {
      final payload = entry.value['payload'];
      if (payload is! Map) continue;
      final normalizedPayload = Map<String, dynamic>.from(payload);
      await _applyDomain(
        prefs,
        entry.key,
        normalizedPayload,
        mergeLocal: firstMigration,
      );
      await _saveBase(
        prefs,
        user.id,
        entry.key,
        (entry.value['revision'] as num?)?.toInt() ?? 0,
        normalizedPayload,
      );
    }
    await prefs.setInt(_cursorKey(user.id), cursor);

    if (firstMigration || latest.isEmpty) {
      await syncDomains(const {
        'favorites',
        'history',
        'settings',
        'search_history',
      });
      await prefs.setBool(_migratedKey(user.id), true);
    }
    await UserProfileStore.checkpoint(user.id);
    return latest.keys.toSet();
  }

  Future<Set<String>> syncDomains(Set<String> domains) async {
    final user = account.user;
    if (user == null || domains.isEmpty) return const {};
    final prefs = await SharedPreferences.getInstance();
    final changedByServer = <String>{};
    for (final domain in domains) {
      final local = _domainSnapshot(prefs, domain);
      final base = _loadBase(prefs, user.id, domain);
      final response = await account.request(
        'POST',
        '/sync',
        authenticated: true,
        body: {
          'domain': domain,
          'baseRevision': base.revision,
          'basePayload': base.payload,
          'payload': local,
        },
      );
      final rawPayload = response['payload'];
      if (rawPayload is! Map) continue;
      final payload = Map<String, dynamic>.from(rawPayload);
      if (!_jsonEqual(local['values'], payload['values'])) {
        await _applyDomain(prefs, domain, payload, mergeLocal: false);
        changedByServer.add(domain);
      }
      await _saveBase(
        prefs,
        user.id,
        domain,
        (response['revision'] as num?)?.toInt() ?? base.revision,
        payload,
      );
    }
    await UserProfileStore.checkpoint(user.id);
    return changedByServer;
  }

  Set<String> _locallyChangedDomains(SharedPreferences prefs, String userId) {
    final changed = <String>{};
    for (final domain in const {
      'favorites',
      'history',
      'settings',
      'search_history',
    }) {
      final local = _domainSnapshot(prefs, domain);
      final base = _loadBase(prefs, userId, domain);
      if (!_jsonEqual(local['values'], base.payload['values'])) {
        changed.add(domain);
      }
    }
    return changed;
  }

  _SyncBase _loadBase(SharedPreferences prefs, String userId, String domain) {
    final raw = prefs.getString(_baseKey(userId, domain));
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map && decoded['payload'] is Map) {
          return _SyncBase(
            revision: (decoded['revision'] as num?)?.toInt() ?? 0,
            payload: Map<String, dynamic>.from(decoded['payload'] as Map),
          );
        }
      } catch (_) {}
    }
    return const _SyncBase(
      revision: 0,
      payload: {'kind': 'snapshot', 'schema': 1, 'values': {}},
    );
  }

  Future<void> _saveBase(
    SharedPreferences prefs,
    String userId,
    String domain,
    int revision,
    Map<String, dynamic> payload,
  ) {
    return prefs.setString(
      _baseKey(userId, domain),
      jsonEncode({'revision': revision, 'payload': payload}),
    );
  }

  bool _jsonEqual(dynamic left, dynamic right) =>
      jsonEncode(left) == jsonEncode(right);

  Map<String, dynamic> _domainSnapshot(SharedPreferences prefs, String domain) {
    final values = <String, dynamic>{};
    for (final key in _keysForDomain(domain)) {
      final value = prefs.get(key);
      if (value != null) values[key] = value;
    }
    return {
      'kind': 'snapshot',
      'schema': 1,
      'updatedAt': DateTime.now().toUtc().millisecondsSinceEpoch,
      'values': values,
    };
  }

  Future<void> _applyDomain(
    SharedPreferences prefs,
    String domain,
    Map<String, dynamic> payload, {
    required bool mergeLocal,
  }) async {
    if (payload['kind'] != 'snapshot') return;
    final rawValues = payload['values'];
    if (rawValues is! Map) return;
    final values = Map<String, dynamic>.from(rawValues);
    for (final key in _keysForDomain(domain)) {
      final remote = values[key];
      final local = prefs.get(key);
      final resolved = mergeLocal ? _mergeValue(key, local, remote) : remote;
      if (resolved == null) {
        await prefs.remove(key);
      } else {
        await _setValue(prefs, key, resolved);
      }
    }
  }

  dynamic _mergeValue(String key, dynamic local, dynamic remote) {
    if (local == null) return remote;
    if (remote == null) return local;
    if (key == 'favorites' || key == 'favorite_playlists') {
      return _mergeJsonLists(local.toString(), remote.toString());
    }
    if (key == 'playback_history_v1') {
      return _mergeHistory(local.toString(), remote.toString());
    }
    if (key == 'search_history' && local is List && remote is List) {
      return <String>{
        ...remote.map((item) => item.toString()),
        ...local.map((item) => item.toString()),
      }.take(20).toList();
    }
    return remote;
  }

  String _mergeJsonLists(String local, String remote) {
    try {
      final localItems = jsonDecode(local);
      final remoteItems = jsonDecode(remote);
      if (localItems is! List || remoteItems is! List) return remote;
      final merged = <String, dynamic>{};
      for (final item in [...remoteItems, ...localItems]) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        final platform = map['platform']?.toString() ?? '';
        final id =
            map['id']?.toString() ?? map['playlist']?['id']?.toString() ?? '';
        if (platform.isNotEmpty && id.isNotEmpty) merged['$platform:$id'] = map;
      }
      return jsonEncode(merged.values.toList());
    } catch (_) {
      return remote;
    }
  }

  String _mergeHistory(String local, String remote) {
    try {
      final localItems = jsonDecode(local);
      final remoteItems = jsonDecode(remote);
      if (localItems is! List || remoteItems is! List) return remote;
      final merged = <String, Map<String, dynamic>>{};
      for (final item in [...remoteItems, ...localItems]) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        final song = map['song'];
        if (song is! Map) continue;
        final platform = song['platform']?.toString() ?? '';
        final id = song['id']?.toString() ?? '';
        final cid = song['bilibiliCid']?.toString() ?? '';
        final historyKey = '$platform:$id:$cid';
        final old = merged[historyKey];
        final playedAt = (map['playedAtMs'] as num?)?.toInt() ?? 0;
        final oldPlayedAt = (old?['playedAtMs'] as num?)?.toInt() ?? 0;
        if (old == null || playedAt >= oldPlayedAt) merged[historyKey] = map;
      }
      final values = merged.values.toList()
        ..sort(
          (a, b) => ((b['playedAtMs'] as num?) ?? 0).compareTo(
            (a['playedAtMs'] as num?) ?? 0,
          ),
        );
      return jsonEncode(values.take(100).toList());
    } catch (_) {
      return remote;
    }
  }

  Future<void> _setValue(
    SharedPreferences prefs,
    String key,
    dynamic value,
  ) async {
    if (value is String) await prefs.setString(key, value);
    if (value is bool) await prefs.setBool(key, value);
    if (value is int) await prefs.setInt(key, value);
    if (value is double) await prefs.setDouble(key, value);
    if (value is List) {
      await prefs.setStringList(
        key,
        value.map((item) => item.toString()).toList(),
      );
    }
  }

  Set<String> _keysForDomain(String domain) => switch (domain) {
    'favorites' => const {'favorites', 'favorite_playlists'},
    'history' => const {'playback_history_v1'},
    'search_history' => const {'search_history'},
    'settings' => UserProfileStore.personalKeys.difference(const {
      'favorites',
      'favorite_playlists',
      'playback_history_v1',
      'search_history',
    }),
    _ => const {},
  };
}

class _SyncBase {
  final int revision;
  final Map<String, dynamic> payload;

  const _SyncBase({required this.revision, required this.payload});
}
