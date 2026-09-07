import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/local_music_library.dart';
import '../theme/app_layout.dart';
import '../widgets/mini_player.dart';
import '../widgets/song_tile.dart';

class LocalMusicScreen extends StatefulWidget {
  const LocalMusicScreen({super.key});
  @override
  State<LocalMusicScreen> createState() => _LocalMusicScreenState();
}

class _LocalMusicScreenState extends State<LocalMusicScreen>
    with WidgetsBindingObserver {
  final _library = LocalMusicLibrary();
  final _search = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_library.scan());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _library.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _library.permissionDenied) {
      unawaited(_library.scan());
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _library,
    builder: (context, _) {
      final all = _library.songs;
      final songs = _query.isEmpty
          ? all
          : all
                .where(
                  (song) => '${song.name} ${song.artist} ${song.album}'
                      .toLowerCase()
                      .contains(_query),
                )
                .toList();
      final player = context.read<PlayerProvider>();
      final layout = AppLayout.fromContext(context);
      return Scaffold(
        appBar: AppBar(
          title: const Text('本地音乐'),
          actions: [
            IconButton(
              key: const ValueKey('local-music-refresh'),
              tooltip: _library.scanning ? '取消扫描' : '重新扫描',
              onPressed: _library.scanning
                  ? _library.cancel
                  : () => _library.scan(requestPermission: true),
              icon: Icon(
                _library.scanning ? Icons.stop_rounded : Icons.refresh_rounded,
              ),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child:
                      MediaQuery.orientationOf(context) == Orientation.landscape
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(
                              width: layout.isCompactLandscape ? 200 : 280,
                              child: _tools(player, songs),
                            ),
                            const VerticalDivider(width: 24),
                            Expanded(child: _list(player, songs)),
                          ],
                        )
                      : Column(
                          children: [
                            SizedBox(height: 166, child: _tools(player, songs)),
                            Expanded(child: _list(player, songs)),
                          ],
                        ),
                ),
              ),
              const MiniPlayer(),
            ],
          ),
        ),
      );
    },
  );

  Widget _tools(
    PlayerProvider player,
    List<SongSearchResult> songs,
  ) => SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('local-music-search'),
          controller: _search,
          maxLength: 100,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search_rounded),
            hintText: '搜索本地音乐',
            counterText: '',
          ),
          onChanged: (value) =>
              setState(() => _query = value.trim().toLowerCase()),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          key: const ValueKey('local-music-play-all'),
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('播放全部'),
          onPressed: songs.isEmpty
              ? null
              : () => player.playFromSearchResults(songs, 0),
        ),
        const SizedBox(height: 8),
        Text(
          '${songs.length} 首${_library.scanning ? ' · 正在扫描' : ''}${_library.reachedLimit ? ' · 已达扫描上限' : ''}',
        ),
        if (_library.scanning)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: LinearProgressIndicator(),
          ),
        if (_library.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _library.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (_library.permissionDenied)
          TextButton.icon(
            key: const ValueKey('local-music-permission'),
            onPressed: _library.permanentlyDenied
                ? () async {
                    await openAppSettings();
                  }
                : () => _library.scan(requestPermission: true),
            icon: const Icon(Icons.folder_open_rounded),
            label: Text(_library.permanentlyDenied ? '打开系统设置' : '授权音频访问'),
          ),
      ],
    ),
  );

  Widget _list(PlayerProvider player, List<SongSearchResult> songs) =>
      songs.isEmpty
      ? const Center(child: Text('暂无本地音乐'))
      : ListView.builder(
          key: const ValueKey('local-music-list'),
          itemCount: songs.length,
          itemBuilder: (context, index) => SongTile(
            song: songs[index],
            showFavorite: true,
            onTap: () => player.playFromSearchResults(songs, index),
            onAddToQueue: () => player.addToQueue(songs[index]),
          ),
        );
}
