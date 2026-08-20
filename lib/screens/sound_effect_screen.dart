import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/sound_effect.dart';
import '../providers/player_provider.dart';
import '../theme/app_theme.dart';

class SoundEffectScreen extends StatefulWidget {
  const SoundEffectScreen({super.key});

  @override
  State<SoundEffectScreen> createState() => _SoundEffectScreenState();
}

class _SoundEffectScreenState extends State<SoundEffectScreen> {
  bool _changing = false;

  Future<void> _toggle(PlayerProvider player, bool enabled) async {
    if (_changing) return;
    setState(() => _changing = true);
    final applied = await player.setSoundEffectEnabled(enabled);
    if (!mounted) return;
    setState(() => _changing = false);
    if (!applied) _showApplyError(player);
  }

  Future<void> _select(PlayerProvider player, SoundEffectPreset preset) async {
    if (_changing) return;
    setState(() => _changing = true);
    final applied = await player.selectSoundEffect(preset);
    if (!mounted) return;
    setState(() => _changing = false);
    if (!applied) _showApplyError(player);
  }

  void _showApplyError(PlayerProvider player) {
    final detail = player.soundEffectStatusMessage.trim();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(detail.isEmpty ? '音效切换失败，已保持原声播放' : detail)),
    );
  }

  @override
  Widget build(BuildContext context) {
    AppColors.syncWithTheme(context);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          key: const ValueKey('sound-effect-back'),
          tooltip: '返回',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        title: const Text('DSP 音效'),
      ),
      body: SafeArea(
        top: false,
        child: Consumer<PlayerProvider>(
          builder: (context, player, _) => LayoutBuilder(
            builder: (context, constraints) {
              final landscape = constraints.maxWidth > constraints.maxHeight;
              if (landscape) {
                final compact = constraints.maxHeight < 480;
                final panelWidth = compact
                    ? (constraints.maxWidth * 0.36).clamp(220.0, 260.0)
                    : (constraints.maxWidth * 0.31).clamp(300.0, 390.0);
                return Row(
                  children: [
                    SizedBox(
                      width: panelWidth,
                      child: _CurrentEffectPanel(
                        player: player,
                        compact: compact,
                        changing: _changing,
                        onToggle: (value) => _toggle(player, value),
                      ),
                    ),
                    VerticalDivider(
                      width: 1,
                      thickness: 1,
                      color: AppColors.outline,
                    ),
                    Expanded(
                      child: _PresetBrowser(
                        player: player,
                        compact: compact,
                        onSelect: (preset) => _select(player, preset),
                      ),
                    ),
                  ],
                );
              }
              return Column(
                children: [
                  _CurrentEffectPanel(
                    player: player,
                    changing: _changing,
                    onToggle: (value) => _toggle(player, value),
                  ),
                  Expanded(
                    child: _PresetBrowser(
                      player: player,
                      onSelect: (preset) => _select(player, preset),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _CurrentEffectPanel extends StatelessWidget {
  final PlayerProvider player;
  final bool compact;
  final bool changing;
  final ValueChanged<bool> onToggle;

  const _CurrentEffectPanel({
    required this.player,
    required this.changing,
    required this.onToggle,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final preset = player.soundEffectPreset;
    final enabled = player.soundEffectEnabled;
    final availabilityText = player.soundEffectAvailable
        ? (enabled ? '正在处理当前播放音频' : '关闭时保持原始声音')
        : (player.soundEffectStatusMessage.isEmpty
              ? '当前设备不支持 DSP'
              : player.soundEffectStatusMessage);
    final vertical = MediaQuery.orientationOf(context) == Orientation.portrait;
    return Container(
      key: const ValueKey('sound-effect-current-panel'),
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 18 : 24,
        vertical: compact ? 12 : (vertical ? 20 : 28),
      ),
      color: const Color(0xFF20252B),
      child: vertical
          ? Row(
              children: [
                _EffectGlyph(
                  preset: preset,
                  enabled: enabled,
                  size: compact ? 56 : 68,
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: _CurrentEffectText(
                    name: preset?.name ?? '原声',
                    detail: availabilityText,
                    compact: compact,
                  ),
                ),
                const SizedBox(width: 12),
                Switch(
                  key: const ValueKey('sound-effect-toggle'),
                  value: enabled,
                  onChanged: player.soundEffectAvailable && !changing
                      ? onToggle
                      : null,
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '当前音效',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.62),
                        fontSize: compact ? 14 : 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Switch(
                      key: const ValueKey('sound-effect-toggle'),
                      value: enabled,
                      onChanged: player.soundEffectAvailable && !changing
                          ? onToggle
                          : null,
                    ),
                  ],
                ),
                Expanded(
                  child: Center(
                    child: _EffectGlyph(
                      preset: preset,
                      enabled: enabled,
                      size: compact ? 70 : 112,
                    ),
                  ),
                ),
                _CurrentEffectText(
                  name: preset?.name ?? '原声',
                  detail: availabilityText,
                  compact: compact,
                ),
              ],
            ),
    );
  }
}

class _CurrentEffectText extends StatelessWidget {
  final String name;
  final String detail;
  final bool compact;

  const _CurrentEffectText({
    required this.name,
    required this.detail,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white,
            fontSize: compact ? 22 : 28,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          detail,
          maxLines: compact ? 1 : 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.64),
            fontSize: compact ? 13 : 16,
          ),
        ),
      ],
    );
  }
}

class _PresetBrowser extends StatelessWidget {
  final PlayerProvider player;
  final bool compact;
  final ValueChanged<SoundEffectPreset> onSelect;

  const _PresetBrowser({
    required this.player,
    required this.onSelect,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final presets = player.soundEffectPresets;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (presets.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                player.soundEffectStatusMessage.isEmpty
                    ? '没有可用的本地音效预设'
                    : player.soundEffectStatusMessage,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ),
          );
        }
        final columns = constraints.maxWidth >= 960
            ? 4
            : constraints.maxWidth >= 640
            ? 3
            : 2;
        final horizontalPadding = compact ? 12.0 : 20.0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                compact ? 10 : 18,
                horizontalPadding,
                compact ? 6 : 10,
              ),
              child: Row(
                children: [
                  Text(
                    '全部音效',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: compact ? 18 : 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '${presets.length}',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: compact ? 14 : 16,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: GridView.builder(
                key: const ValueKey('sound-effect-preset-grid'),
                padding: EdgeInsets.fromLTRB(
                  horizontalPadding,
                  4,
                  horizontalPadding,
                  compact ? 12 : 20,
                ),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: compact ? 10 : 14,
                  mainAxisSpacing: compact ? 10 : 14,
                  childAspectRatio: compact ? 1.65 : 1.5,
                ),
                itemCount: presets.length,
                itemBuilder: (context, index) {
                  final preset = presets[index];
                  final selected =
                      player.soundEffectEnabled &&
                      player.soundEffectPreset?.id == preset.id &&
                      player.soundEffectPreset?.type == preset.type;
                  return _PresetTile(
                    preset: preset,
                    selected: selected,
                    compact: compact,
                    enabled: player.soundEffectAvailable,
                    onTap: () => onSelect(preset),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PresetTile extends StatelessWidget {
  final SoundEffectPreset preset;
  final bool selected;
  final bool compact;
  final bool enabled;
  final VoidCallback onTap;

  const _PresetTile({
    required this.preset,
    required this.selected,
    required this.compact,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = _accentFor(preset);
    return Material(
      key: ValueKey('sound-effect-preset-${preset.id}'),
      color: selected ? accent.withValues(alpha: 0.14) : AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.small),
        side: BorderSide(
          color: selected ? accent : AppColors.outline,
          width: selected ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: EdgeInsets.all(compact ? 10 : 14),
          child: Row(
            children: [
              Container(
                width: compact ? 42 : 52,
                height: compact ? 42 : 52,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(AppRadius.small),
                ),
                child: Icon(
                  _iconFor(preset),
                  color: accent,
                  size: compact ? 24 : 29,
                ),
              ),
              SizedBox(width: compact ? 9 : 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      preset.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: compact ? 15 : 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (!compact && preset.description.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        preset.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_circle_rounded, color: accent, size: 22),
            ],
          ),
        ),
      ),
    );
  }
}

class _EffectGlyph extends StatelessWidget {
  final SoundEffectPreset? preset;
  final bool enabled;
  final double size;

  const _EffectGlyph({
    required this.preset,
    required this.enabled,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final accent = preset == null
        ? const Color(0xFFB8C0C8)
        : _accentFor(preset!);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: enabled
            ? accent.withValues(alpha: 0.2)
            : Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(
          color: enabled
              ? accent.withValues(alpha: 0.68)
              : Colors.white.withValues(alpha: 0.16),
        ),
      ),
      child: Icon(
        preset == null ? Icons.graphic_eq_rounded : _iconFor(preset!),
        color: enabled ? accent : Colors.white54,
        size: size * 0.52,
      ),
    );
  }
}

Color _accentFor(SoundEffectPreset preset) {
  final text = '${preset.name} ${preset.tags.join(' ')}';
  if (text.contains('低音')) return const Color(0xFFFF6B5F);
  if (text.contains('环绕') || text.contains('声场')) {
    return const Color(0xFF25BFA3);
  }
  if (text.contains('人声') || text.contains('旋律')) {
    return const Color(0xFFE45E91);
  }
  if (text.contains('环境') || text.contains('房') || text.contains('室')) {
    return const Color(0xFF6BB46E);
  }
  if (text.contains('保真') || text.contains('清澈')) {
    return const Color(0xFFE5A82F);
  }
  return const Color(0xFF4D8EDB);
}

IconData _iconFor(SoundEffectPreset preset) {
  final text = '${preset.name} ${preset.tags.join(' ')}';
  if (text.contains('低音')) return Icons.speaker_rounded;
  if (text.contains('环绕') || text.contains('声场')) {
    return Icons.surround_sound_rounded;
  }
  if (text.contains('人声')) return Icons.record_voice_over_rounded;
  if (text.contains('环境') || text.contains('房') || text.contains('室')) {
    return Icons.location_city_rounded;
  }
  if (text.contains('耳机')) return Icons.headphones_rounded;
  if (text.contains('保真') || text.contains('清澈')) {
    return Icons.high_quality_rounded;
  }
  return Icons.graphic_eq_rounded;
}
