import 'package:flutter/material.dart';

import '../services/backup_service.dart';
import '../services/favorite_service.dart';
import '../theme/app_layout.dart';

/// Shows the restore scope picker shared by local, pasted, LAN and WebDAV
/// restore flows. Every section starts selected so the existing one-click
/// restore behavior remains the default.
Future<BackupRestoreSelection?> showBackupRestoreSelectionDialog(
  BuildContext context,
  BackupRestoreContents contents,
) {
  return showDialog<BackupRestoreSelection>(
    context: context,
    builder: (_) => _BackupRestoreOptionsDialog(contents: contents),
  );
}

class _BackupRestoreOptionsDialog extends StatefulWidget {
  final BackupRestoreContents contents;

  const _BackupRestoreOptionsDialog({required this.contents});

  @override
  State<_BackupRestoreOptionsDialog> createState() =>
      _BackupRestoreOptionsDialogState();
}

class _BackupRestoreOptionsDialogState
    extends State<_BackupRestoreOptionsDialog> {
  late final Set<BackupRestoreSection> _selected =
      widget.contents.availableSections;

  static const _labels = <BackupRestoreSection, String>{
    BackupRestoreSection.songs: '收藏歌曲',
    BackupRestoreSection.bilibili: 'B站收藏',
    BackupRestoreSection.playlists: '收藏歌单',
    BackupRestoreSection.apiKey: '音乐 API Key',
    BackupRestoreSection.aiAssistant: 'AI 助手配置（模型、中转站、Key、宠物）',
    BackupRestoreSection.playerSettings: '播放器设置（音质、音源等）',
  };

  static const _icons = <BackupRestoreSection, IconData>{
    BackupRestoreSection.songs: Icons.music_note_rounded,
    BackupRestoreSection.bilibili: Icons.video_library_outlined,
    BackupRestoreSection.playlists: Icons.queue_music_rounded,
    BackupRestoreSection.apiKey: Icons.key_outlined,
    BackupRestoreSection.aiAssistant: Icons.smart_toy_outlined,
    BackupRestoreSection.playerSettings: Icons.tune_rounded,
  };

  void _close(FavoriteImportMode mode) {
    if (_selected.isEmpty) return;
    Navigator.pop(
      context,
      BackupRestoreSelection(mode: mode, sections: _selected),
    );
  }

  @override
  Widget build(BuildContext context) {
    final layout = AppLayout.fromContext(context);
    final maxHeight = (MediaQuery.sizeOf(context).height * 0.52)
        .clamp(180.0, 420.0)
        .toDouble();
    final available = widget.contents.availableSections;
    final allSelected = _selected.length == available.length;
    return AlertDialog(
      key: const ValueKey('backup-restore-options-dialog'),
      title: const Text('选择还原内容'),
      content: SizedBox(
        width: double.maxFinite,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '可按需选择，未选内容不会被修改',
                        style: TextStyle(fontSize: layout.secondarySize),
                      ),
                    ),
                    TextButton(
                      key: const ValueKey('backup-restore-toggle-all'),
                      onPressed: () => setState(() {
                        if (allSelected) {
                          _selected.clear();
                        } else {
                          _selected
                            ..clear()
                            ..addAll(available);
                        }
                      }),
                      child: Text(allSelected ? '清空' : '全选'),
                    ),
                  ],
                ),
                const Divider(height: 12),
                for (final section in BackupRestoreSection.values)
                  CheckboxListTile(
                    key: ValueKey('backup-restore-section-${section.name}'),
                    value: _selected.contains(section),
                    isThreeLine: !widget.contents.contains(section),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    secondary: Icon(_icons[section]),
                    title: Text(
                      _labels[section]!,
                      style: TextStyle(fontSize: layout.bodySize),
                    ),
                    subtitle: widget.contents.contains(section)
                        ? null
                        : const Text('备份中没有此项'),
                    onChanged: widget.contents.contains(section)
                        ? (value) => setState(() {
                            if (value == true) {
                              _selected.add(section);
                            } else {
                              _selected.remove(section);
                            }
                          })
                        : null,
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('backup-restore-cancel'),
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        OutlinedButton(
          key: const ValueKey('backup-restore-replace'),
          onPressed: _selected.isEmpty
              ? null
              : () => _close(FavoriteImportMode.replace),
          child: const Text('覆盖'),
        ),
        FilledButton(
          key: const ValueKey('backup-restore-merge'),
          onPressed: _selected.isEmpty
              ? null
              : () => _close(FavoriteImportMode.merge),
          child: const Text('合并'),
        ),
      ],
    );
  }
}
