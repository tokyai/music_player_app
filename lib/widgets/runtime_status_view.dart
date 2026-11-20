import 'package:flutter/material.dart';

/// 原生启动和故障页，横屏下入口仍可见。SHIXIAOYANG，2026/11/19。
class RuntimeStatusView extends StatelessWidget {
  final String status;
  final String? error;
  final VoidCallback onRetry;
  const RuntimeStatusView({
    super.key,
    required this.status,
    required this.onRetry,
    this.error,
  });

  @override
  Widget build(BuildContext context) {
    // 只让中间状态区域滚动，窄横屏的重试入口不会被长错误文本挤出屏幕。
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.library_music, size: 40),
                const SizedBox(height: 12),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(status, textAlign: TextAlign.center),
                        if (error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(error!, textAlign: TextAlign.center),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (error == null)
                  const CircularProgressIndicator()
                else
                  FilledButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试并恢复本地版本'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
