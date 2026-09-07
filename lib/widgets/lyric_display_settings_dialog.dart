import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/lyric_style.dart';

class LyricDisplaySettingsDialog extends StatefulWidget {
  const LyricDisplaySettingsDialog({super.key});

  @override
  State<LyricDisplaySettingsDialog> createState() =>
      _LyricDisplaySettingsDialogState();
}

class _LyricDisplaySettingsDialogState
    extends State<LyricDisplaySettingsDialog> {
  double _fontSize = 42;
  double _lineSpacing = 44;
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final size = prefs.get(LyricStylePreferences.fontSizeKey);
      final spacing = prefs.get(LyricStylePreferences.lineSpacingKey);
      setState(() {
        if (size is num && size.isFinite) {
          final normalized = size < 32 ? 32.0 : size.toDouble();
          if (LyricStylePreferences.fontSizes.contains(normalized)) {
            _fontSize = normalized;
          }
        }
        if (spacing is num && spacing.isFinite) {
          _lineSpacing = spacing.toDouble().clamp(
            LyricStylePreferences.minimumLineSpacing,
            LyricStylePreferences.maximumLineSpacing,
          );
        }
      });
    } catch (error) {
      if (mounted) setState(() => _error = '读取歌词显示设置失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save(String key, double value) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final previous = prefs.get(key);
      try {
        if (!await prefs.setDouble(key, value)) throw StateError('存储不可用');
      } catch (error) {
        try {
          if (previous is num && previous.isFinite) {
            await prefs.setDouble(key, previous.toDouble());
          } else {
            await prefs.remove(key);
          }
        } catch (rollbackError) {
          debugPrint('回退歌词显示设置失败: $rollbackError');
        }
        rethrow;
      }
      if (!mounted) return;
      setState(() {
        if (key == LyricStylePreferences.fontSizeKey) {
          _fontSize = value;
        } else {
          _lineSpacing = value;
        }
      });
    } catch (error) {
      if (mounted) {
        await _load();
        if (mounted) setState(() => _error = '保存歌词显示设置失败：$error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    key: const ValueKey('lyric-display-settings-dialog'),
    insetPadding: const EdgeInsets.all(12),
    clipBehavior: Clip.antiAlias,
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 560,
        maxHeight: MediaQuery.sizeOf(context).height - 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 20, right: 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '歌词字号和间距',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  key: const ValueKey('lyric-display-settings-close'),
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('字号'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final size in LyricStylePreferences.fontSizes)
                        ChoiceChip(
                          key: ValueKey('lyric-font-size-${size.round()}'),
                          label: Text('${size.round()}'),
                          selected: _fontSize == size,
                          onSelected: _busy
                              ? null
                              : (_) => _save(
                                  LyricStylePreferences.fontSizeKey,
                                  size,
                                ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Expanded(child: Text('上下间距')),
                      Text('${_lineSpacing.round()} px'),
                    ],
                  ),
                  Slider(
                    key: const ValueKey('lyric-line-spacing-slider'),
                    value: _lineSpacing,
                    min: LyricStylePreferences.minimumLineSpacing,
                    max: LyricStylePreferences.maximumLineSpacing,
                    divisions: 28,
                    label: '${_lineSpacing.round()} px',
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _lineSpacing = value),
                    onChangeEnd: (value) =>
                        _save(LyricStylePreferences.lineSpacingKey, value),
                  ),
                  if (_error != null)
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
