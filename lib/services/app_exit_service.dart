import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/ai_assistant_controller.dart';
import '../providers/player_provider.dart';
import 'floating_capsule_service.dart';

/// Coordinates a deliberate, complete application shutdown.
class AppExitService {
  static const channelName = 'music_player/app_lifecycle';
  static const MethodChannel _channel = MethodChannel(channelName);

  static bool _requestInProgress = false;

  const AppExitService._();

  static Future<void> confirmAndExit(BuildContext context) async {
    if (_requestInProgress) return;
    _requestInProgress = true;
    var confirmed = false;
    try {
      final player = context.read<PlayerProvider>();
      final assistant = Provider.of<AiAssistantController?>(
        context,
        listen: false,
      );
      confirmed =
          await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              key: const ValueKey('complete-exit-dialog'),
              title: const Text('完全关闭软件？'),
              content: const Text('将保存当前播放队列和进度，并停止播放、语音及系统迷你窗。'),
              actions: [
                TextButton(
                  key: const ValueKey('complete-exit-cancel'),
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('取消'),
                ),
                FilledButton.icon(
                  key: const ValueKey('complete-exit-confirm'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(dialogContext).colorScheme.error,
                    foregroundColor: Theme.of(
                      dialogContext,
                    ).colorScheme.onError,
                  ),
                  onPressed: () => Navigator.pop(dialogContext, true),
                  icon: const Icon(Icons.power_settings_new_rounded),
                  label: const Text('完全退出'),
                ),
              ],
            ),
          ) ??
          false;
      if (!confirmed) return;

      await _runCleanupStep('停止 AI 助手', () async {
        try {
          await assistant?.stopSession(restoreMusic: false);
        } finally {
          await assistant?.releasePreloadedVoiceModel();
        }
      }, const Duration(seconds: 2));
      await _runCleanupStep(
        '保存并停止播放器',
        player.prepareForAppExit,
        const Duration(seconds: 4),
      );
      await _runCleanupStep(
        '关闭系统迷你窗',
        FloatingCapsuleService.hide,
        const Duration(seconds: 1),
      );
      await _requestNativeExit();
    } catch (error, stackTrace) {
      debugPrint('完全退出流程失败: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (confirmed) await _fallbackExit();
    } finally {
      // Once confirmed, keep the guard raised until the native process exits.
      if (!confirmed) _requestInProgress = false;
    }
  }

  static Future<void> _runCleanupStep(
    String label,
    Future<void> Function() action,
    Duration timeout,
  ) async {
    try {
      await action().timeout(timeout);
    } catch (error, stackTrace) {
      // One plugin must not prevent the remaining resources from being closed.
      debugPrint('$label失败，继续退出: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  static Future<void> _requestNativeExit() async {
    try {
      final accepted =
          await _channel
              .invokeMethod<bool>('exit')
              .timeout(const Duration(seconds: 2)) ??
          false;
      if (accepted) return;
    } catch (error, stackTrace) {
      debugPrint('原生完全退出调用失败: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
    await _fallbackExit();
  }

  static Future<void> _fallbackExit() async {
    try {
      await SystemNavigator.pop(animated: true);
    } catch (error, stackTrace) {
      debugPrint('系统退出调用失败: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  @visibleForTesting
  static void resetForTesting() {
    _requestInProgress = false;
  }
}
