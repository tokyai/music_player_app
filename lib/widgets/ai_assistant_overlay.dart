import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/ai_assistant.dart';
import '../providers/ai_assistant_controller.dart';
import '../providers/ai_config_controller.dart';
import '../theme/app_layout.dart';
import '../theme/app_theme.dart';
import 'kuzai_pet.dart';

class AiAssistantFloatingButton extends StatefulWidget {
  final double? size;

  const AiAssistantFloatingButton({super.key, this.size});

  @override
  State<AiAssistantFloatingButton> createState() =>
      _AiAssistantFloatingButtonState();
}

class _AiAssistantFloatingButtonState extends State<AiAssistantFloatingButton> {
  AiAssistantController? _controller;
  bool _opening = false;

  @override
  void dispose() {
    _controller?.removeListener(_handleControllerChange);
    super.dispose();
  }

  void _handleControllerChange() {
    if (mounted) setState(() {});
  }

  void _attachController(AiAssistantController? controller) {
    if (identical(_controller, controller)) return;
    _controller?.removeListener(_handleControllerChange);
    _controller = controller;
    _controller?.addListener(_handleControllerChange);
  }

  Future<void> _openAssistant() async {
    if (_opening) return;
    _opening = true;
    _attachController(
      Provider.of<AiAssistantController?>(context, listen: false),
    );
    try {
      await showAiAssistantPanel(context);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('打开 AI 助理失败：$error')));
      }
    } finally {
      _opening = false;
    }
  }

  KuzaiPetMode get _petMode => switch (_controller?.state) {
    AiSessionState.initializing => KuzaiPetMode.waking,
    AiSessionState.listening => KuzaiPetMode.listening,
    AiSessionState.processing => KuzaiPetMode.thinking,
    AiSessionState.speaking => KuzaiPetMode.speaking,
    AiSessionState.textOnly => KuzaiPetMode.textOnly,
    AiSessionState.paused => KuzaiPetMode.paused,
    AiSessionState.stopping => KuzaiPetMode.stopping,
    AiSessionState.error => KuzaiPetMode.error,
    _ => KuzaiPetMode.idle,
  };

  @override
  Widget build(BuildContext context) {
    final layout = AppLayout.fromContext(context);
    final baseSize = layout.isCompactLandscape ? 68.0 : 88.0;
    return KuzaiPet(
      key: const ValueKey('ai-assistant-fab'),
      size: widget.size ?? baseSize,
      mode: _petMode,
      onTap: () => unawaited(_openAssistant()),
    );
  }
}

/// Full-page host for the movable assistant pet. Its persisted coordinates are
/// normalized so the pet stays inside the visible area after rotation or when
/// moving between phone and car-display sizes.
class AiAssistantPetOverlay extends StatefulWidget {
  final EdgeInsets reservedInsets;

  const AiAssistantPetOverlay({
    super.key,
    this.reservedInsets = EdgeInsets.zero,
  });

  @override
  State<AiAssistantPetOverlay> createState() => _AiAssistantPetOverlayState();
}

class _AiAssistantPetOverlayState extends State<AiAssistantPetOverlay> {
  Offset? _dragOffset;

  @override
  Widget build(BuildContext context) {
    final config = Provider.of<AiConfigController?>(context);
    final layout = AppLayout.fromContext(context);
    final petScale = config?.petScale ?? 1;
    final petSize = (layout.isCompactLandscape ? 68.0 : 88.0) * petScale;
    final petWidth = petSize * 1.12;
    final position = config?.petPosition ?? AiPetPosition.centered;

    return Padding(
      padding: widget.reservedInsets,
      child: SafeArea(
        minimum: const EdgeInsets.all(8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final maxX = (constraints.maxWidth - petWidth)
                .clamp(0.0, double.infinity)
                .toDouble();
            final maxY = (constraints.maxHeight - petSize)
                .clamp(0.0, double.infinity)
                .toDouble();
            final persisted = Offset(position.x * maxX, position.y * maxY);
            final current = _clampOffset(_dragOffset ?? persisted, maxX, maxY);
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  key: const ValueKey('ai-assistant-pet-position'),
                  left: current.dx,
                  top: current.dy,
                  width: petWidth,
                  height: petSize,
                  child: GestureDetector(
                    key: const ValueKey('ai-assistant-pet-drag'),
                    behavior: HitTestBehavior.translucent,
                    onPanStart: (_) {
                      if (!mounted) return;
                      setState(() => _dragOffset = current);
                    },
                    onPanUpdate: (details) {
                      if (!mounted) return;
                      setState(() {
                        _dragOffset = _clampOffset(
                          (_dragOffset ?? current) + details.delta,
                          maxX,
                          maxY,
                        );
                      });
                    },
                    onPanEnd: (_) {
                      if (!mounted) return;
                      final offset = _dragOffset ?? current;
                      setState(() => _dragOffset = null);
                      if (config == null) return;
                      unawaited(_savePetPosition(config, offset, maxX, maxY));
                    },
                    child: AiAssistantFloatingButton(size: petSize),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Offset _clampOffset(Offset value, double maxX, double maxY) => Offset(
    value.dx.clamp(0.0, maxX).toDouble(),
    value.dy.clamp(0.0, maxY).toDouble(),
  );

  Future<void> _savePetPosition(
    AiConfigController config,
    Offset offset,
    double maxX,
    double maxY,
  ) async {
    try {
      await config.setPetPosition(
        AiPetPosition(
          x: maxX <= 0 ? 0 : offset.dx / maxX,
          y: maxY <= 0 ? 0 : offset.dy / maxY,
        ),
      );
    } catch (_) {
      // Position persistence is best effort; a storage failure must not take
      // down the page after the drag gesture has already completed.
    }
  }
}

Future<void> showAiAssistantPanel(BuildContext context) async {
  final controller = Provider.of<AiAssistantController?>(
    context,
    listen: false,
  );
  final configController = Provider.of<AiConfigController?>(
    context,
    listen: false,
  );
  if (controller == null || configController == null) return;
  await configController.ready;
  if (!context.mounted) return;
  if (!configController.config.isComplete) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('请先到“设置 > AI 音乐助理”填写 URL、Key 和模型')),
      );
    return;
  }

  final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
  if (landscape) {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        key: const ValueKey('ai-assistant-dialog'),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.all(8),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760, maxHeight: 620),
          child: AiAssistantPanel(controller: controller),
        ),
      ),
    );
  } else {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      enableDrag: false,
      isDismissible: false,
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.84,
        child: AiAssistantPanel(controller: controller),
      ),
    );
  }
}

class AiAssistantPanel extends StatefulWidget {
  final AiAssistantController controller;

  const AiAssistantPanel({super.key, required this.controller});

  @override
  State<AiAssistantPanel> createState() => _AiAssistantPanelState();
}

class _AiAssistantPanelState extends State<AiAssistantPanel> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  bool _closing = false;
  bool _wasActive = false;

  AiAssistantController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.addListener(_handleControllerChange);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (controller.isActive) {
        _wasActive = true;
      } else {
        unawaited(controller.startSession());
      }
    });
  }

  @override
  void dispose() {
    controller.removeListener(_handleControllerChange);
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _handleControllerChange() {
    if (!mounted) return;
    if (controller.isActive) _wasActive = true;
    if (_wasActive && !controller.isActive && !_closing) {
      _closing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      });
      return;
    }
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      unawaited(
        _scrollController
            .animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
            )
            .catchError((_) {}),
      );
    });
  }

  void _close() {
    if (_closing) return;
    _closing = true;
    final assistant = controller;
    if (mounted) {
      final navigator = Navigator.of(context);
      if (navigator.canPop()) navigator.pop();
    }
    unawaited(_stopAssistant(assistant));
  }

  Future<void> _stopAssistant(AiAssistantController assistant) async {
    try {
      await assistant.stopSession();
    } catch (_) {
      // Closing the panel must remain best effort even if audio cleanup fails.
    }
  }

  Future<void> _send() async {
    if (!mounted || _closing) return;
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    _inputController.clear();
    try {
      await controller.sendText(text);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('发送消息失败：$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    AppColors.syncWithTheme(context);
    final layout = AppLayout.fromContext(context);
    final compact = layout.isCompactLandscape;
    final landscape = layout.isLandscape;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Material(
        color: Colors.transparent,
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.background,
            border: Border.all(color: AppColors.outline),
            borderRadius: BorderRadius.circular(
              landscape ? AppRadius.panel : AppRadius.card,
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.cardShadow,
                blurRadius: landscape ? 18 : 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(
              landscape ? AppRadius.panel : AppRadius.card,
            ),
            child: SafeArea(
              top: false,
              child: Column(
                children: [
                  _buildHeader(layout),
                  Divider(height: 1, color: AppColors.outline),
                  Expanded(child: _buildMessages(layout)),
                  if (controller.transcript.isNotEmpty)
                    _buildTranscript(compact),
                  _buildStatus(compact, voiceOnly: landscape),
                  _buildComposer(compact, voiceOnly: landscape),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(AppLayout layout) {
    final compact = layout.isCompactLandscape;
    final landscape = layout.isLandscape;
    final avatarSize = compact ? 46.0 : 58.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        landscape ? (compact ? 12 : 18) : 18,
        landscape ? (compact ? 6 : 10) : 8,
        landscape ? (compact ? 8 : 12) : 6,
        landscape ? (compact ? 6 : 10) : 6,
      ),
      child: Row(
        children: [
          if (landscape)
            Container(
              width: avatarSize * 1.12,
              height: avatarSize,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.primarySoft,
                borderRadius: BorderRadius.circular(AppRadius.control),
                border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.22),
                ),
              ),
              child: IgnorePointer(
                child: KuzaiPet(
                  key: const ValueKey('ai-assistant-pet-avatar'),
                  size: avatarSize,
                  mode: KuzaiPetMode.idle,
                  onTap: () {},
                ),
              ),
            )
          else
            Container(
              width: compact ? 34 : 40,
              height: compact ? 34 : 40,
              decoration: BoxDecoration(
                color: AppColors.primarySoft,
                borderRadius: BorderRadius.circular(AppRadius.control),
              ),
              child: const Icon(
                Icons.auto_awesome_rounded,
                color: AppColors.primary,
              ),
            ),
          const SizedBox(width: 10),
          Expanded(
            child: landscape
                ? _buildLandscapeIdentity(compact)
                : Text(
                    'AI 小助理',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: compact ? 18 : 21,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
          IconButton(
            key: const ValueKey('ai-assistant-new-session'),
            tooltip: '新对话',
            onPressed: controller.isActive
                ? () => unawaited(controller.newSession())
                : null,
            icon: const Icon(Icons.add_comment_outlined),
          ),
          Container(
            key: const ValueKey('ai-assistant-close'),
            width: landscape ? (compact ? 58 : 62) : 50,
            height: landscape ? (compact ? 58 : 62) : 50,
            decoration: BoxDecoration(
              color: landscape ? AppColors.primarySoft : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadius.control),
              border: landscape
                  ? Border.all(color: AppColors.primary.withValues(alpha: 0.25))
                  : null,
            ),
            child: IconButton(
              tooltip: '结束并关闭',
              onPressed: _close,
              constraints: BoxConstraints.tightFor(
                width: landscape ? (compact ? 58 : 62) : 50,
                height: landscape ? (compact ? 58 : 62) : 50,
              ),
              padding: EdgeInsets.zero,
              icon: Icon(
                Icons.close_rounded,
                size: landscape ? (compact ? 31 : 34) : 30,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLandscapeIdentity(bool compact) {
    final state = controller.state;
    final statusColor = state == AiSessionState.error
        ? Colors.redAccent
        : AppColors.primary;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '库仔 AI 宠物',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: compact ? 18 : 21,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: statusColor.withValues(alpha: AppColors.isDark ? 0.2 : 0.1),
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                state == AiSessionState.error
                    ? Icons.warning_amber_rounded
                    : Icons.auto_awesome_rounded,
                size: compact ? 14 : 16,
                color: statusColor,
              ),
              const SizedBox(width: 4),
              Text(
                state == AiSessionState.error ? '需要检查连接' : '陪你听歌聊天',
                style: TextStyle(
                  color: statusColor,
                  fontSize: compact ? 12 : 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTranscript(bool compact) {
    return Container(
      key: const ValueKey('ai-assistant-live-transcript'),
      width: double.infinity,
      margin: EdgeInsets.fromLTRB(compact ? 10 : 16, 4, compact ? 10 : 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.primarySoft,
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.18)),
      ),
      child: Text(
        controller.transcript,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: AppColors.textPrimary),
      ),
    );
  }

  Widget _buildMessages(AppLayout layout) {
    final messages = controller.messages;
    if (messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.record_voice_over_rounded,
                size: layout.isCompactLandscape ? 36 : 50,
                color: AppColors.primary,
              ),
              const SizedBox(height: 10),
              Text(
                '直接说出你的问题或想听的歌曲',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: layout.bodySize,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '说“退下吧”或“结束对话”即可退出',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      key: const ValueKey('ai-assistant-messages'),
      controller: _scrollController,
      padding: EdgeInsets.symmetric(
        horizontal: layout.isCompactLandscape ? 10 : 16,
        vertical: 10,
      ),
      itemCount: messages.length,
      itemBuilder: (context, index) => _MessageBubble(message: messages[index]),
    );
  }

  Widget _buildStatus(bool compact, {required bool voiceOnly}) {
    final state = controller.state;
    final color = state == AiSessionState.error
        ? Colors.redAccent
        : state == AiSessionState.listening
        ? AppColors.primary
        : AppColors.textSecondary;
    final icon = switch (state) {
      AiSessionState.listening => Icons.mic_rounded,
      AiSessionState.processing => Icons.psychology_alt_rounded,
      AiSessionState.speaking => Icons.volume_up_rounded,
      AiSessionState.error || AiSessionState.textOnly => Icons.info_outline,
      _ => Icons.graphic_eq_rounded,
    };
    final statusLabel = voiceOnly && state == AiSessionState.textOnly
        ? '语音不可用，请点击麦克风重试'
        : controller.statusLabel;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 18, vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              statusLabel,
              key: const ValueKey('ai-assistant-status'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontSize: compact ? 13 : 14),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComposer(bool compact, {required bool voiceOnly}) {
    final busy =
        controller.state == AiSessionState.processing ||
        controller.state == AiSessionState.initializing;
    final microphoneTooltip = controller.state == AiSessionState.speaking
        ? '打断播报并说话'
        : controller.isListening
        ? '暂停聆听'
        : '继续聆听';
    if (voiceOnly) {
      return Padding(
        padding: EdgeInsets.fromLTRB(
          compact ? 10 : 16,
          4,
          compact ? 10 : 16,
          compact ? 8 : 14,
        ),
        child: SizedBox(
          key: const ValueKey('ai-assistant-voice-action'),
          width: double.infinity,
          height: compact ? 62 : 72,
          child: Tooltip(
            message: microphoneTooltip,
            child: FilledButton.icon(
              key: const ValueKey('ai-assistant-microphone'),
              onPressed: busy
                  ? null
                  : () => unawaited(controller.toggleListening()),
              icon: Icon(
                controller.isListening
                    ? Icons.mic_rounded
                    : Icons.mic_off_outlined,
                size: compact ? 29 : 32,
              ),
              label: Text(
                controller.state == AiSessionState.speaking
                    ? '打断播报，继续说话'
                    : controller.isListening
                    ? '正在聆听 · 点击暂停'
                    : '点击开始语音对话',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: compact ? 17 : 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: controller.isListening
                    ? AppColors.primary
                    : AppColors.surfaceSoft,
                foregroundColor: controller.isListening
                    ? Colors.white
                    : AppColors.textPrimary,
                disabledBackgroundColor: AppColors.surfaceSoft,
                disabledForegroundColor: AppColors.textSecondary,
                side: BorderSide(
                  color: controller.isListening
                      ? AppColors.primary
                      : AppColors.outline,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.control),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 18),
              ),
            ),
          ),
        ),
      );
    }
    final microphone = IconButton.filledTonal(
      key: const ValueKey('ai-assistant-microphone'),
      tooltip: microphoneTooltip,
      onPressed: busy ? null : () => unawaited(controller.toggleListening()),
      icon: Icon(
        controller.isListening ? Icons.mic_rounded : Icons.mic_off_outlined,
      ),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(
        compact ? 8 : 12,
        4,
        compact ? 8 : 12,
        compact ? 8 : 12,
      ),
      child: Row(
        children: [
          microphone,
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              key: const ValueKey('ai-assistant-text-field'),
              controller: _inputController,
              enabled: !busy,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => unawaited(_send()),
              decoration: const InputDecoration(
                hintText: '也可以输入文字…',
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            key: const ValueKey('ai-assistant-send'),
            tooltip: '发送',
            onPressed: busy ? null : () => unawaited(_send()),
            icon: const Icon(Icons.send_rounded),
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final AiConversationMessage message;

  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final user = message.role == AiMessageRole.user;
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 620),
        margin: const EdgeInsets.only(bottom: 9),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
        decoration: BoxDecoration(
          color: user ? AppColors.primary : AppColors.surface,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(user ? 16 : 4),
            bottomRight: Radius.circular(user ? 4 : 16),
          ),
          border: user ? null : Border.all(color: AppColors.outline),
        ),
        child: Text(
          message.text,
          style: TextStyle(
            color: user ? Colors.white : AppColors.textPrimary,
            height: 1.4,
          ),
        ),
      ),
    );
  }
}
