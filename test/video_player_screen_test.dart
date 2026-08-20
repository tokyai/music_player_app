import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/screens/video_player_screen.dart';
import 'package:music_player_app/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('invalid MV sources render an error instead of throwing', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const VideoPlayerScreen(
          url: '',
          alternateUrls: ['not a URL'],
          title: '测试 MV',
          artist: '测试歌手',
          platform: MusicPlatform.bilibili,
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('MV 播放地址无效或为空'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
