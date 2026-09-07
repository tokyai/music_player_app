import 'package:flutter/material.dart';

import '../services/sleep_timer.dart';

class SleepTimerDialog extends StatefulWidget {
  const SleepTimerDialog({super.key, required this.timer});
  final SleepTimer timer;

  @override
  State<SleepTimerDialog> createState() => _SleepTimerDialogState();
}

class _SleepTimerDialogState extends State<SleepTimerDialog> {
  double _minutes = 30;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.timer,
    builder: (context, _) => Dialog(
      key: const ValueKey('sleep-timer-dialog'),
      insetPadding: const EdgeInsets.all(12),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 480,
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
                      '睡眠定时',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('sleep-timer-close'),
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
                    Text(switch (widget.timer.mode) {
                      SleepTimerMode.off => '未开启',
                      SleepTimerMode.duration =>
                        '剩余 ${formatSleepRemaining(widget.timer.remaining)}',
                      SleepTimerMode.endOfTrack => '当前歌曲结束后停止',
                    }, key: const ValueKey('sleep-timer-status')),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final minutes in [15, 30, 60, 90])
                          ChoiceChip(
                            key: ValueKey('sleep-timer-preset-$minutes'),
                            label: Text('$minutes 分钟'),
                            selected: _minutes == minutes,
                            onSelected: (_) =>
                                setState(() => _minutes = minutes.toDouble()),
                          ),
                      ],
                    ),
                    Slider(
                      key: const ValueKey('sleep-timer-minutes'),
                      value: _minutes,
                      min: 5,
                      max: 120,
                      divisions: 23,
                      label: '${_minutes.round()} 分钟',
                      onChanged: (value) => setState(() => _minutes = value),
                    ),
                    FilledButton.icon(
                      key: const ValueKey('sleep-timer-start'),
                      icon: const Icon(Icons.timer_outlined),
                      label: Text('${_minutes.round()} 分钟后停止'),
                      onPressed: () {
                        widget.timer.start(Duration(minutes: _minutes.round()));
                        Navigator.pop(context);
                      },
                    ),
                    TextButton.icon(
                      key: const ValueKey('sleep-timer-track-end'),
                      icon: const Icon(Icons.music_note_rounded),
                      label: const Text('播完当前歌曲停止'),
                      onPressed: () {
                        widget.timer.stopAfterTrack();
                        Navigator.pop(context);
                      },
                    ),
                    if (widget.timer.active)
                      TextButton.icon(
                        key: const ValueKey('sleep-timer-cancel'),
                        icon: const Icon(Icons.timer_off_outlined),
                        label: const Text('取消定时'),
                        onPressed: () {
                          widget.timer.cancel();
                          Navigator.pop(context);
                        },
                      ),
                    if (widget.timer.error != null)
                      Text(
                        widget.timer.error!,
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
    ),
  );
}
