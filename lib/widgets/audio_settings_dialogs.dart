import 'package:flutter/material.dart';

import '../models/audio_effects.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/audio_effects_service.dart';

class AudioQualityDialog extends StatefulWidget {
  const AudioQualityDialog({super.key, required this.player});
  final PlayerProvider player;

  @override
  State<AudioQualityDialog> createState() => _AudioQualityDialogState();
}

class _AudioQualityDialogState extends State<AudioQualityDialog> {
  late MusicPlatform _platform =
      widget.player.currentSong?.platform == MusicPlatform.kugou
      ? MusicPlatform.qq
      : widget.player.currentSong?.platform ?? MusicPlatform.qq;
  String? _error;

  Future<void> _select(Future<void> Function() action) async {
    setState(() => _error = null);
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = '切换音质失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.player,
    builder: (context, _) {
      final player = widget.player;
      final busy = player.changingAudioQuality;
      final options =
          <({String value, String label, Future<void> Function() select})>[
            if (_platform == MusicPlatform.netease)
              for (final level in NeteaseLevel.values)
                (
                  value: level.value,
                  label: level.label,
                  select: () => player.setNeteaseLevel(level),
                )
            else if (_platform == MusicPlatform.qq)
              for (final level in CommonLevel.values)
                (
                  value: level.value,
                  label: level.label,
                  select: () => player.setCommonLevel(level),
                )
            else
              for (final stream in player.bilibiliAudioQualities)
                (
                  value: '${stream.quality}',
                  label: stream.label,
                  select: () => player.setBilibiliAudioQuality(stream.quality),
                ),
          ];
      final selected = switch (_platform) {
        MusicPlatform.netease => player.neteaseLevel.value,
        MusicPlatform.qq || MusicPlatform.kugou => player.commonLevel.value,
        MusicPlatform.bilibili => '${player.bilibiliAudioQuality}',
      };
      return _AudioDialogFrame(
        dialogKey: const ValueKey('audio-quality-dialog'),
        title: '全局音质',
        busy: busy,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: DropdownButton<MusicPlatform>(
              key: const ValueKey('audio-quality-platform'),
              value: _platform,
              isExpanded: true,
              items: const [
                DropdownMenuItem(
                  value: MusicPlatform.qq,
                  child: Text('QQ / 酷狗'),
                ),
                DropdownMenuItem(
                  value: MusicPlatform.netease,
                  child: Text('网易云'),
                ),
                DropdownMenuItem(
                  value: MusicPlatform.bilibili,
                  child: Text('B站音频'),
                ),
              ],
              onChanged: busy
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() {
                          _platform = value;
                          _error = null;
                        });
                      }
                    },
            ),
          ),
          if (options.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('当前没有可用的 B站音频流'),
            ),
          RadioGroup<String>(
            groupValue: selected,
            onChanged: (value) {
              if (busy || value == null) return;
              _select(
                options.firstWhere((option) => option.value == value).select,
              );
            },
            child: Column(
              children: [
                for (final option in options)
                  RadioListTile<String>(
                    key: ValueKey('audio-quality-${option.value}'),
                    value: option.value,
                    title: Text(option.label),
                    enabled: !busy,
                  ),
              ],
            ),
          ),
          if (_error != null) _ErrorText(_error!),
          if (_platform == MusicPlatform.bilibili &&
              player.bilibiliVideoQualities.isNotEmpty)
            ExpansionTile(
              key: const ValueKey('audio-quality-video'),
              title: const Text('视频清晰度'),
              children: [
                RadioGroup<int>(
                  groupValue: player.bilibiliVideoQuality,
                  onChanged: (value) {
                    if (value != null) {
                      _select(() => player.setBilibiliVideoQuality(value));
                    }
                  },
                  child: Column(
                    children: [
                      for (final stream in player.bilibiliVideoQualities)
                        RadioListTile<int>(
                          value: stream.quality,
                          title: Text(stream.label),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          if (player.errorMessage != null) _ErrorText(player.errorMessage!),
        ],
      );
    },
  );
}

class AudioEffectsDialog extends StatefulWidget {
  const AudioEffectsDialog({super.key, required this.service});
  final AudioEffectsService service;

  @override
  State<AudioEffectsDialog> createState() => _AudioEffectsDialogState();
}

class _AudioEffectsDialogState extends State<AudioEffectsDialog> {
  late AudioEffectsSettings _draft = widget.service.settings;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.service.ready.then((_) {
      if (mounted && !_busy) setState(() => _draft = widget.service.settings);
    });
  }

  Future<void> _save(AudioEffectsSettings next) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _draft = next;
    });
    try {
      await widget.service.setSettings(next);
    } catch (error) {
      if (mounted) {
        setState(() {
          _draft = widget.service.settings;
          _error = '保存音效失败：$error';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.service,
    builder: (context, _) {
      final service = widget.service;
      final available = service.supported && !_busy && !service.saving;
      final enabled = available && _draft.enabled;
      final status = !service.supported
          ? '当前平台不支持音效处理'
          : service.failures.isNotEmpty
          ? '设备暂不支持：${service.failures.join('、')}'
          : !_draft.enabled
          ? '原声'
          : !service.hasSession
          ? '等待播放'
          : service.applying
          ? '正在应用'
          : '已应用';
      return _AudioDialogFrame(
        dialogKey: const ValueKey('audio-effects-dialog'),
        title: '全局音效',
        busy: _busy,
        children: [
          SwitchListTile(
            key: const ValueKey('audio-effects-master'),
            title: const Text('音效'),
            subtitle: Text(status, key: const ValueKey('audio-effects-status')),
            value: _draft.enabled,
            onChanged: available
                ? (value) => _save(_draft.copyWith(enabled: value))
                : null,
          ),
          const Divider(height: 1),
          SwitchListTile(
            key: const ValueKey('audio-effects-equalizer'),
            title: const Text('均衡器'),
            value: _draft.equalizerEnabled,
            onChanged: enabled
                ? (value) => _save(_draft.copyWith(equalizerEnabled: value))
                : null,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: DropdownButton<EqualizerPreset>(
              key: const ValueKey('audio-effects-preset'),
              isExpanded: true,
              value: _draft.preset,
              hint: const Text('自定义'),
              items: [
                for (final preset in EqualizerPreset.values)
                  DropdownMenuItem(value: preset, child: Text(preset.label)),
              ],
              onChanged: enabled && _draft.equalizerEnabled
                  ? (value) {
                      if (value != null) {
                        _save(_draft.copyWith(bands: value.bands));
                      }
                    }
                  : null,
            ),
          ),
          for (var i = 0; i < AudioEffectsSettings.frequencies.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  SizedBox(
                    width: 52,
                    child: Text(
                      '${AudioEffectsSettings.frequencyLabels[i]} Hz',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      key: ValueKey('audio-effects-band-$i'),
                      value: _draft.bands[i],
                      min: -12,
                      max: 12,
                      divisions: 24,
                      label: '${_draft.bands[i].round()} dB',
                      onChanged: enabled && _draft.equalizerEnabled
                          ? (value) {
                              final bands = List<double>.of(_draft.bands)
                                ..[i] = value;
                              setState(
                                () => _draft = _draft.copyWith(bands: bands),
                              );
                            }
                          : null,
                      onChangeEnd: (_) => _save(_draft),
                    ),
                  ),
                  SizedBox(
                    width: 42,
                    child: Text(
                      '${_draft.bands[i].round()} dB',
                      textAlign: TextAlign.end,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 1),
          SwitchListTile(
            key: const ValueKey('audio-effects-bass'),
            title: const Text('低音增强'),
            value: _draft.bassEnabled,
            onChanged: enabled
                ? (value) => _save(_draft.copyWith(bassEnabled: value))
                : null,
          ),
          _slider(
            'audio-effects-bass-strength',
            _draft.bassStrength,
            0,
            1,
            enabled && _draft.bassEnabled,
            (value) => _draft.copyWith(bassStrength: value),
          ),
          SwitchListTile(
            key: const ValueKey('audio-effects-surround'),
            title: const Text('环绕'),
            value: _draft.surroundEnabled,
            onChanged: enabled
                ? (value) => _save(_draft.copyWith(surroundEnabled: value))
                : null,
          ),
          _slider(
            'audio-effects-surround-strength',
            _draft.surroundStrength,
            0,
            0.7,
            enabled && _draft.surroundEnabled,
            (value) => _draft.copyWith(surroundStrength: value),
          ),
          SwitchListTile(
            key: const ValueKey('audio-effects-balance'),
            title: const Text('声道平衡'),
            value: _draft.balanceEnabled,
            onChanged: enabled
                ? (value) => _save(_draft.copyWith(balanceEnabled: value))
                : null,
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [Text('左'), Text('居中'), Text('右')],
            ),
          ),
          _slider(
            'audio-effects-balance-value',
            _draft.balance,
            -1,
            1,
            enabled && _draft.balanceEnabled,
            (value) => _draft.copyWith(balance: value),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: OutlinedButton.icon(
              key: const ValueKey('audio-effects-reset'),
              onPressed: _busy
                  ? null
                  : () => _save(const AudioEffectsSettings()),
              icon: const Icon(Icons.restart_alt_rounded),
              label: const Text('恢复原声'),
            ),
          ),
          if (_error != null) _ErrorText(_error!),
        ],
      );
    },
  );

  Widget _slider(
    String key,
    double value,
    double min,
    double max,
    bool enabled,
    AudioEffectsSettings Function(double) update,
  ) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Slider(
      key: ValueKey(key),
      value: value,
      min: min,
      max: max,
      divisions: 20,
      label: '${(value * 100).round()}%',
      onChanged: enabled
          ? (value) => setState(() => _draft = update(value))
          : null,
      onChangeEnd: (_) => _save(_draft),
    ),
  );
}

class _AudioDialogFrame extends StatelessWidget {
  const _AudioDialogFrame({
    required this.dialogKey,
    required this.title,
    required this.children,
    this.busy = false,
  });
  final Key dialogKey;
  final String title;
  final List<Widget> children;
  final bool busy;

  @override
  Widget build(BuildContext context) => Dialog(
    key: dialogKey,
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
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (busy)
                  const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                IconButton(
                  key: ValueKey(
                    '${title == '全局音质' ? 'audio-quality' : 'audio-effects'}-close',
                  ),
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: SingleChildScrollView(child: Column(children: children)),
          ),
        ],
      ),
    ),
  );
}

class _ErrorText extends StatelessWidget {
  const _ErrorText(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Text(
      message,
      style: TextStyle(color: Theme.of(context).colorScheme.error),
    ),
  );
}
