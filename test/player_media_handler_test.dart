import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/services/player_media_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('media-session controls use the application playback queue', () async {
    final player = _MediaTestPlayer();
    final handler = PlayerMediaHandler(player);
    addTearDown(() {
      handler.dispose();
      player.dispose();
    });

    player.loadQueue();

    expect(handler.queue.value.length, 2);
    expect(handler.mediaItem.value?.title, 'First song');
    expect(
      handler.playbackState.value.controls,
      containsAll([MediaControl.skipToPrevious, MediaControl.skipToNext]),
    );

    await handler.click(MediaButton.media);
    await handler.click(MediaButton.next);
    await handler.click(MediaButton.previous);
    await handler.seek(const Duration(seconds: 12));
    await handler.skipToQueueItem(1);
    await handler.click(MediaButton.media);

    expect(player.playCalls, 1);
    expect(player.nextCalls, 1);
    expect(player.previousCalls, 1);
    expect(player.lastSeek, const Duration(seconds: 12));
    expect(player.lastQueueIndex, 1);
    expect(player.pauseCalls, 1);
  });

  test('bounds the published queue for very large application queues', () {
    final player = _MediaTestPlayer(itemCount: 3000, currentIndex: 2500);
    final handler = PlayerMediaHandler(player);
    addTearDown(() {
      handler.dispose();
      player.dispose();
    });

    player.loadQueue();

    expect(handler.queue.value.length, 2000);
    expect(handler.mediaItem.value?.title, 'Song 2501');
    expect(handler.playbackState.value.queueIndex, 1500);
  });
}

class _MediaTestPlayer extends PlayerProvider {
  final List<PlayQueueItem> _items = [];
  final int itemCount;
  final int initialIndex;
  int _index = -1;
  bool _playing = false;
  int playCalls = 0;
  int pauseCalls = 0;
  int nextCalls = 0;
  int previousCalls = 0;
  Duration? lastSeek;
  int? lastQueueIndex;

  _MediaTestPlayer({this.itemCount = 2, int currentIndex = 0})
    : initialIndex = currentIndex;

  void loadQueue() {
    if (itemCount == 2) {
      _items.addAll([
        PlayQueueItem(
          platform: MusicPlatform.qq,
          id: 'first',
          name: 'First song',
          artist: 'Artist',
          album: 'Album',
          duration: 180,
        ),
        PlayQueueItem(
          platform: MusicPlatform.netease,
          id: 'second',
          name: 'Second song',
          artist: 'Artist',
          album: 'Album',
          duration: 210,
        ),
      ]);
    } else {
      _items.addAll(
        List.generate(
          itemCount,
          (index) => PlayQueueItem(
            platform: MusicPlatform.qq,
            id: '$index',
            name: 'Song ${index + 1}',
            artist: 'Artist',
            album: 'Album',
            duration: 180,
          ),
        ),
      );
    }
    _index = initialIndex;
    notifyListeners();
  }

  @override
  List<PlayQueueItem> get queue => _items;

  @override
  int get currentIndex => _index;

  @override
  PlayQueueItem? get currentSong =>
      _index >= 0 && _index < _items.length ? _items[_index] : null;

  @override
  bool get isPlaying => _playing;

  @override
  Future<void> playPause() async {
    playCalls++;
    _playing = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    _playing = false;
    notifyListeners();
  }

  @override
  Future<void> playNext() async {
    nextCalls++;
    _index = (_index + 1) % _items.length;
    notifyListeners();
  }

  @override
  Future<void> playPrevious() async {
    previousCalls++;
    _index = (_index - 1 + _items.length) % _items.length;
    notifyListeners();
  }

  @override
  Future<void> seekTo(Duration position) async {
    lastSeek = position;
  }

  @override
  Future<void> playQueueItem(int index) async {
    lastQueueIndex = index;
    _index = index;
    notifyListeners();
  }
}
