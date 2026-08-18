import 'package:flutter/material.dart';
import '../models/song.dart';
import '../theme/app_layout.dart';
import '../theme/app_theme.dart';

/// 歌单导入对话框（支持 QQ音乐 / 网易云）
class PlaylistImportDialog extends StatefulWidget {
  final void Function(MusicPlatform platform, String id) onImport;

  const PlaylistImportDialog({super.key, required this.onImport});

  @override
  State<PlaylistImportDialog> createState() => _PlaylistImportDialogState();
}

class _PlaylistImportDialogState extends State<PlaylistImportDialog> {
  final _controller = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  MusicPlatform _platform = MusicPlatform.qq;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 从链接或纯 ID 中提取歌单 ID
  String _extractId(String input) {
    final t = input.trim();
    final m = RegExp(r'\d{5,}').firstMatch(t);
    return m?.group(0) ?? t;
  }

  @override
  Widget build(BuildContext context) {
    AppColors.syncWithTheme(context);
    final isQQ = _platform == MusicPlatform.qq;
    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height;
    final compactLandscape = isLandscape && size.height <= 420;
    final layout = AppLayout.fromContext(context);
    return AlertDialog(
      scrollable: true,
      insetPadding: EdgeInsets.symmetric(
        horizontal: isLandscape ? (compactLandscape ? 28 : 56) : 24,
        vertical: compactLandscape ? 12 : 24,
      ),
      title: const Text('导入歌单'),
      content: SizedBox(
        width: isLandscape ? (compactLandscape ? 480 : 600) : 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<MusicPlatform>(
                segments: const [
                  ButtonSegment(
                    value: MusicPlatform.qq,
                    label: Text('QQ音乐'),
                    icon: Icon(Icons.headphones),
                  ),
                  ButtonSegment(
                    value: MusicPlatform.netease,
                    label: Text('网易云'),
                    icon: Icon(Icons.music_note),
                  ),
                ],
                selected: {_platform},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _platform = s.first),
                style: SegmentedButton.styleFrom(
                  visualDensity: compactLandscape
                      ? VisualDensity.compact
                      : VisualDensity.standard,
                  textStyle: TextStyle(
                    fontSize: compactLandscape ? 16 : layout.bodySize,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                isQQ
                    ? '输入 QQ 歌单链接或 ID\n如: https://y.qq.com/n/ryqq/playlist/8912082986'
                    : '输入网易云歌单 ID\n如: 5202687076',
                style: TextStyle(fontSize: layout.bodySize, height: 1.35),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _controller,
                decoration: InputDecoration(
                  labelText: isQQ ? 'QQ 歌单链接 / ID' : '歌单 ID',
                  border: const OutlineInputBorder(),
                  hintText: isQQ ? '粘贴链接或输入 ID' : '例如: 5202687076',
                ),
                keyboardType: TextInputType.url,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return '请输入歌单 ID 或链接';
                  final id = _extractId(v);
                  if (!RegExp(r'^\d{5,}$').hasMatch(id)) {
                    return '请输入有效的歌单 ID 或链接';
                  }
                  return null;
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            if (_formKey.currentState!.validate()) {
              final id = _extractId(_controller.text);
              if (id.isEmpty) return;
              Navigator.pop(context);
              widget.onImport(_platform, id);
            }
          },
          child: const Text('导入'),
        ),
      ],
    );
  }
}
