import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/song.dart';
import '../providers/player_provider.dart';

/// Bridges Android media-session commands to the application's real queue.
class PlayerMediaHandler extends BaseAudioHandler with SeekHandler {
  // Android media-session clients do not need the application's entire queue.
  // Keep a bounded window so a very large playlist cannot be duplicated into
  // thousands of MediaItem objects during a native callback.
  static const _maxPublishedQueueItems = 2000;

  PlayerMediaHandler(this._player) {
    _player.addListener(_syncFromPlayer);
    _syncFromPlayer();
  }

  final PlayerProvider _player;
  int? _publishedQueueFingerprint;
  int? _publishedPlaybackFingerprint;
  List<MediaItem> _publishedQueue = const [];
  int _publishedQueueStartIndex = 0;
  bool _disposed = false;

  void _syncFromPlayer() {
    if (_disposed) return;
    try {
      _publishQueue();
      _publishCurrentItem();
      _publishPlaybackState();
    } catch (error, stackTrace) {
      // A just_audio callback can race handler teardown. Do not let a stale
      // native callback terminate the Flutter isolate while its streams are
      // being released.
      if (!_disposed) {
        debugPrint('系统媒体状态同步失败: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }
  }

  void _publishQueue() {
    final items = _player.queue;
    final currentIndex = _player.currentIndex;
    final startIndex = _publishedStartIndex(items.length, currentIndex);
    final fingerprint = Object.hash(
      _player.queueSessionId,
      items.length,
      currentIndex,
      startIndex,
      items.isNotEmpty ? _itemFingerprint(items.first) : 0,
      items.isNotEmpty ? _itemFingerprint(items.last) : 0,
      currentIndex >= 0 && currentIndex < items.length
          ? _itemFingerprint(items[currentIndex])
          : 0,
    );
    if (_publishedQueueFingerprint == fingerprint) return;

    final endIndex = (startIndex + _maxPublishedQueueItems)
        .clamp(startIndex, items.length)
        .toInt();
    _publishedQueue = [
      for (var index = startIndex; index < endIndex; index++)
        _toMediaItem(items[index], index),
    ];
    _publishedQueueStartIndex = startIndex;
    _publishedQueueFingerprint = fingerprint;
    queue.add(_publishedQueue);
  }

  int _publishedStartIndex(int itemCount, int currentIndex) {
    if (itemCount <= _maxPublishedQueueItems || itemCount == 0) return 0;
    final safeIndex = currentIndex.clamp(0, itemCount - 1).toInt();
    final centered = safeIndex - _maxPublishedQueueItems ~/ 2;
    return centered.clamp(0, itemCount - _maxPublishedQueueItems).toInt();
  }

  int _itemFingerprint(PlayQueueItem item) => Object.hash(
    item.platform,
    item.id,
    item.name,
    item.artist,
    item.album,
    item.coverUrl,
    item.duration,
    item.bilibiliCid,
  );

  void _publishCurrentItem() {
    final index = _player.currentIndex;
    final publishedIndex = index - _publishedQueueStartIndex;
    if (publishedIndex < 0 || publishedIndex >= _publishedQueue.length) {
      if (mediaItem.valueOrNull != null) mediaItem.add(null);
      return;
    }

    final queuedItem = _publishedQueue[publishedIndex];
    final actualDuration = _player.duration > Duration.zero
        ? _player.duration
        : queuedItem.duration;
    final current = queuedItem.copyWith(duration: actualDuration);
    final previous = mediaItem.valueOrNull;
    if (previous?.id == current.id &&
        previous?.title == current.title &&
        previous?.artist == current.artist &&
        previous?.album == current.album &&
        previous?.artUri == current.artUri &&
        previous?.duration == current.duration) {
      return;
    }
    mediaItem.add(current);
  }

  void _publishPlaybackState({bool force = false}) {
    final hasCurrent = _player.currentSong != null;
    final processingState = _processingState(hasCurrent);
    final positionMarker = _player.isPlaying
        ? _player.position.inSeconds
        : _player.position.inMilliseconds;
    final fingerprint = Object.hash(
      hasCurrent,
      processingState,
      _player.isPlaying,
      positionMarker,
      _player.buffered.inSeconds,
      _player.currentIndex,
      _player.playMode,
    );
    if (!force && _publishedPlaybackFingerprint == fingerprint) return;
    _publishedPlaybackFingerprint = fingerprint;

    final controls = hasCurrent
        ? <MediaControl>[
            MediaControl.skipToPrevious,
            if (_player.isPlaying) MediaControl.pause else MediaControl.play,
            MediaControl.stop,
            MediaControl.skipToNext,
          ]
        : const <MediaControl>[];
    playbackState.add(
      PlaybackState(
        controls: controls,
        systemActions: hasCurrent
            ? const {
                MediaAction.seek,
                MediaAction.seekForward,
                MediaAction.seekBackward,
              }
            : const {},
        androidCompactActionIndices: hasCurrent ? const [0, 1, 3] : const [],
        processingState: processingState,
        playing: _player.isPlaying,
        updatePosition: _player.position,
        bufferedPosition: _player.buffered,
        speed: _player.audioPlayer.speed,
        queueIndex: hasCurrent
            ? _player.currentIndex - _publishedQueueStartIndex
            : null,
        repeatMode: _player.playMode == PlayMode.repeat
            ? AudioServiceRepeatMode.one
            : AudioServiceRepeatMode.all,
        shuffleMode: _player.playMode == PlayMode.shuffle
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
      ),
    );
  }

  AudioProcessingState _processingState(bool hasCurrent) {
    if (!hasCurrent) return AudioProcessingState.idle;
    if (_player.isLoading) return AudioProcessingState.loading;
    return switch (_player.audioPlayer.processingState) {
      ProcessingState.idle => AudioProcessingState.idle,
      ProcessingState.loading => AudioProcessingState.loading,
      ProcessingState.buffering => AudioProcessingState.buffering,
      ProcessingState.ready => AudioProcessingState.ready,
      ProcessingState.completed => AudioProcessingState.completed,
    };
  }

  MediaItem _toMediaItem(PlayQueueItem item, int index) {
    return MediaItem(
      id: '${item.platform.code}:${item.id}:$index',
      title: item.name,
      artist: item.artist,
      album: item.album,
      duration: item.duration == null
          ? null
          : Duration(seconds: item.duration!),
      artUri: _artUri(item.coverUrl),
      extras: {'platform': item.platform.code, 'songId': item.id},
    );
  }

  Uri? _artUri(String? value) {
    if (value == null || value.isEmpty) return null;
    final uri = Uri.tryParse(value);
    return uri != null && uri.hasScheme ? uri : null;
  }

  @override
  Future<void> play() async {
    if (!_player.isPlaying) await _player.playPause();
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    await _player.seekTo(position);
    _publishPlaybackState(force: true);
  }

  @override
  Future<void> skipToNext() => _player.playNext();

  @override
  Future<void> skipToPrevious() => _player.playPrevious();

  @override
  Future<void> skipToQueueItem(int index) => _player.playQueueItem(
    index + _publishedQueueStartIndex,
  );

  void dispose() {
    _disposed = true;
    _player.removeListener(_syncFromPlayer);
  }
}
