import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/ai_assistant.dart';
import '../providers/ai_assistant_controller.dart';
import '../providers/ai_config_controller.dart';
import '../theme/app_layout.dart';
import '../theme/app_theme.dart';

class AiAssistantFloatingButton extends StatelessWidget {
  const AiAssistantFloatingButton({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '打开 AI 小助理',
      child: FloatingActionButton(
        key: const ValueKey('ai-assistant-fab'),
        heroTag: 'ai-assistant-fab',
        tooltip: 'AI 小助理',
        onPressed: () => showAiAssistantPanel(context),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.primary,
        child: const Icon(Icons.auto_awesome_rounded),
      ),
    );
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
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  void _close() {
    if (_closing) return;
    _closing = true;
    final assistant = controller;
    Navigator.of(context).pop();
    unawaited(assistant.stopSession());
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    _inputController.clear();
    await controller.sendText(text);
  }

  @override
  Widget build(BuildContext context) {
    AppColors.syncWithTheme(context);
    final layout = AppLayout.fromContext(context);
    final compact = layout.isCompactLandscape;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Material(
        color: AppColors.background,
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              _buildHeader(compact),
              Divider(height: 1, color: AppColors.outline),
              Expanded(child: _buildMessages(layout)),
              if (controller.transcript.isNotEmpty)
                Container(
                  key: const ValueKey('ai-assistant-live-transcript'),
                  width: double.infinity,
                  margin: EdgeInsets.fromLTRB(
                    compact ? 10 : 16,
                    4,
                    compact ? 10 : 16,
                    4,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primarySoft,
                    borderRadius: BorderRadius.circular(AppRadius.control),
                  ),
                  child: Text(
                    controller.transcript,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppColors.textPrimary),
                  ),
                ),
              _buildStatus(compact, voiceOnly: layout.isLandscape),
              _buildComposer(compact, voiceOnly: layout.isLandscape),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(bool compact) {
    return Padding(
      padding: EdgeInsets.fromLTRB(compact ? 12 : 18, 8, 6, 6),
      child: Row(
        children: [
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
            child: Text(
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
          IconButton(
            key: const ValueKey('ai-assistant-close'),
            tooltip: '结束并关闭',
            onPressed: _close,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
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
    final microphone = IconButton.filledTonal(
      key: const ValueKey('ai-assistant-microphone'),
      tooltip: controller.state == AiSessionState.speaking
          ? '打断播报并说话'
          : controller.isListening
          ? '暂停聆听'
          : '继续聆听',
      onPressed: busy ? null : () => unawaited(controller.toggleListening()),
      icon: Icon(
        controller.isListening ? Icons.mic_rounded : Icons.mic_off_outlined,
      ),
    );
    if (voiceOnly) {
      return Padding(
        padding: EdgeInsets.fromLTRB(8, 4, 8, compact ? 8 : 12),
        child: Center(child: microphone),
      );
    }
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
