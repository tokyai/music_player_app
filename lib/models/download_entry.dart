import 'song.dart';

enum DownloadStatus {
  queued,
  downloading,
  processing,
  paused,
  completed,
  failed,
}

class DownloadEntry {
  DownloadEntry({
    required this.id,
    required this.song,
    required this.quality,
    this.status = DownloadStatus.queued,
    this.fileName,
    this.error,
    this.warning,
  });
  final String id;
  final SongSearchResult song;
  final String quality;
  DownloadStatus status;
  String? fileName;
  String? error;
  String? warning;
  int received = 0;
  int total = 0;
  SongSearchResult get offlineSong =>
      SongSearchResult.fromJson({...song.toJson(), 'downloadId': id});

  static final idPattern = RegExp(r'^[a-f0-9]{24}$');
  static final filePattern = RegExp(
    r'^[a-f0-9]{24}\.(mp3|flac|m4a|aac|ogg|opus|wav|ape|audio)$',
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'song': song.toJson(),
    'quality': quality,
    'status': status.name,
    'fileName': fileName,
    'error': error,
    'warning': warning,
  };

  factory DownloadEntry.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final rawSong = json['song'];
    final quality = json['quality'];
    final fileName = json['fileName'];
    if (id is! String ||
        !idPattern.hasMatch(id) ||
        rawSong is! Map ||
        quality is! String ||
        quality.length > 32 ||
        (fileName != null &&
            (fileName is! String ||
                !filePattern.hasMatch(fileName) ||
                !fileName.startsWith('$id.')))) {
      throw const FormatException('下载记录无效');
    }
    final status = DownloadStatus.values
        .where((value) => value.name == json['status'])
        .firstOrNull;
    if (status == null) throw const FormatException('下载状态无效');
    if (status == DownloadStatus.completed && fileName == null) {
      throw const FormatException('下载文件名缺失');
    }
    final song = SongSearchResult.fromJson(Map<String, dynamic>.from(rawSong));
    if (song.platform == MusicPlatform.local || song.downloadId != null) {
      throw const FormatException('本地音频无需下载');
    }
    return DownloadEntry(
      id: id,
      song: song,
      quality: quality,
      status: status,
      fileName: fileName as String?,
      error: _text(json['error']),
      warning: _text(json['warning']),
    );
  }

  static String? _text(Object? value) => value is String
      ? (value.length > 200 ? value.substring(0, 200) : value)
      : null;
}
