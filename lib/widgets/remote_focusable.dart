import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/player_provider.dart';

class RemoteFocusable extends StatefulWidget {
  const RemoteFocusable({
    super.key,
    required this.child,
    this.onPressed,
    this.onKeyEvent,
    this.onFocusChange,
    this.autofocus = false,
    this.enabled = true,
    this.semanticLabel,
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
  });

  final Widget child;
  final VoidCallback? onPressed;
  final FocusOnKeyEventCallback? onKeyEvent;
  final ValueChanged<bool>? onFocusChange;
  final bool autofocus;
  final bool enabled;
  final String? semanticLabel;
  final BorderRadiusGeometry borderRadius;

  @override
  State<RemoteFocusable> createState() => _RemoteFocusableState();
}

class _RemoteFocusableState extends State<RemoteFocusable> {
  bool _showFocus = false;

  @override
  Widget build(BuildContext context) {
    final focusColor = Theme.of(context).colorScheme.primary;
    final actions = <Type, Action<Intent>>{};
    if (widget.onPressed != null) {
      actions[ActivateIntent] = CallbackAction<ActivateIntent>(
        onInvoke: (_) {
          widget.onPressed!();
          return null;
        },
      );
    }

    return Focus(
      canRequestFocus: false,
      onKeyEvent: widget.onKeyEvent,
      child: FocusableActionDetector(
        enabled: widget.enabled,
        autofocus: widget.autofocus,
        actions: actions,
        onFocusChange: widget.onFocusChange,
        onShowFocusHighlight: (show) {
          if (_showFocus != show) setState(() => _showFocus = show);
        },
        child: Semantics(
          button: widget.onPressed != null,
          enabled: widget.enabled,
          label: widget.semanticLabel,
          onTap: widget.enabled ? widget.onPressed : null,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.enabled ? widget.onPressed : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              foregroundDecoration: BoxDecoration(
                borderRadius: widget.borderRadius,
                border: _showFocus
                    ? Border.all(color: focusColor, width: 3)
                    : null,
              ),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

class TvRemoteScope extends StatelessWidget {
  const TvRemoteScope({
    super.key,
    required this.navigatorKey,
    required this.child,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  Future<void> _handleBack() async {
    final navigator = navigatorKey.currentState;
    if (navigator != null && await navigator.maybePop()) return;
    await SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerProvider>();
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.goBack): _RemoteBackIntent(),
        SingleActivator(LogicalKeyboardKey.browserBack): _RemoteBackIntent(),
        SingleActivator(LogicalKeyboardKey.gameButtonB): _RemoteBackIntent(),
        SingleActivator(LogicalKeyboardKey.escape): _RemoteBackIntent(),
        SingleActivator(LogicalKeyboardKey.mediaPlayPause):
            _RemotePlayPauseIntent(),
        SingleActivator(LogicalKeyboardKey.mediaTrackPrevious):
            _RemotePreviousIntent(),
        SingleActivator(LogicalKeyboardKey.mediaTrackNext): _RemoteNextIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _RemoteBackIntent: CallbackAction<_RemoteBackIntent>(
            onInvoke: (_) {
              unawaited(_handleBack());
              return null;
            },
          ),
          _RemotePlayPauseIntent: CallbackAction<_RemotePlayPauseIntent>(
            onInvoke: (_) {
              unawaited(player.playPause());
              return null;
            },
          ),
          _RemotePreviousIntent: CallbackAction<_RemotePreviousIntent>(
            onInvoke: (_) {
              unawaited(player.playPrevious());
              return null;
            },
          ),
          _RemoteNextIntent: CallbackAction<_RemoteNextIntent>(
            onInvoke: (_) {
              unawaited(player.playNext());
              return null;
            },
          ),
        },
        child: FocusTraversalGroup(child: child),
      ),
    );
  }
}

class _RemoteBackIntent extends Intent {
  const _RemoteBackIntent();
}

class _RemotePlayPauseIntent extends Intent {
  const _RemotePlayPauseIntent();
}

class _RemotePreviousIntent extends Intent {
  const _RemotePreviousIntent();
}

class _RemoteNextIntent extends Intent {
  const _RemoteNextIntent();
}
