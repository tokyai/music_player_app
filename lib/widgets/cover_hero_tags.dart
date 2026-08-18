import '../models/song.dart';

String playerCoverHeroTag(MusicPlatform platform, String id) =>
    'player-cover-${platform.code}:$id';

String playlistCoverHeroTag(MusicPlatform platform, String id) =>
    'playlist-cover-${platform.code}:$id';
