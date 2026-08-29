import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/ai_assistant.dart';
import 'kuzai_pet.dart';

enum AssistantPetMode {
  idle,
  waking,
  listening,
  thinking,
  speaking,
  textOnly,
  paused,
  stopping,
  error,
}

enum AssistantPetInteraction { none, wave, petting }

enum AssistantPetDragDirection { none, left, right }

class AssistantPet extends StatelessWidget {
  const AssistantPet({
    super.key,
    required this.appearance,
    required this.size,
    required this.mode,
    required this.interaction,
    required this.onTap,
    required this.onLongPressStart,
    this.dragging = false,
    this.dragDirection = AssistantPetDragDirection.none,
    this.interactionRevision = 0,
    this.interactive = true,
    this.onInteractionComplete,
  });

  final AiPetAppearance appearance;
  final double size;
  final AssistantPetMode mode;
  final AssistantPetInteraction interaction;
  final VoidCallback onTap;
  final GestureLongPressStartCallback onLongPressStart;
  final bool dragging;
  final AssistantPetDragDirection dragDirection;
  final int interactionRevision;
  final bool interactive;
  final VoidCallback? onInteractionComplete;

  @override
  Widget build(BuildContext context) {
    if (appearance == AiPetAppearance.kuzai) {
      return KuzaiPet(
        size: size,
        mode: _kuzaiMode,
        onTap: onTap,
        onLongPressStart: onLongPressStart,
        dragging: dragging,
        dragDirection: switch (dragDirection) {
          AssistantPetDragDirection.left => -1,
          AssistantPetDragDirection.right => 1,
          AssistantPetDragDirection.none => 0,
        },
        interactive: interactive,
      );
    }
    return _SpriteAssistantPet(
      appearance: appearance,
      size: size,
      mode: mode,
      interaction: interaction,
      onTap: onTap,
      onLongPressStart: onLongPressStart,
      dragging: dragging,
      dragDirection: dragDirection,
      interactionRevision: interactionRevision,
      interactive: interactive,
      onInteractionComplete: onInteractionComplete,
    );
  }

  KuzaiPetMode get _kuzaiMode => switch (mode) {
    AssistantPetMode.idle => KuzaiPetMode.idle,
    AssistantPetMode.waking => KuzaiPetMode.waking,
    AssistantPetMode.listening => KuzaiPetMode.listening,
    AssistantPetMode.thinking => KuzaiPetMode.thinking,
    AssistantPetMode.speaking => KuzaiPetMode.speaking,
    AssistantPetMode.textOnly => KuzaiPetMode.textOnly,
    AssistantPetMode.paused => KuzaiPetMode.paused,
    AssistantPetMode.stopping => KuzaiPetMode.stopping,
    AssistantPetMode.error => KuzaiPetMode.error,
  };
}

class _SpriteAssistantPet extends StatefulWidget {
  const _SpriteAssistantPet({
    required this.appearance,
    required this.size,
    required this.mode,
    required this.interaction,
    required this.onTap,
    required this.onLongPressStart,
    required this.dragging,
    required this.dragDirection,
    required this.interactionRevision,
    required this.interactive,
    required this.onInteractionComplete,
  });

  final AiPetAppearance appearance;
  final double size;
  final AssistantPetMode mode;
  final AssistantPetInteraction interaction;
  final VoidCallback onTap;
  final GestureLongPressStartCallback onLongPressStart;
  final bool dragging;
  final AssistantPetDragDirection dragDirection;
  final int interactionRevision;
  final bool interactive;
  final VoidCallback? onInteractionComplete;

  @override
  State<_SpriteAssistantPet> createState() => _SpriteAssistantPetState();
}

class _SpriteAssistantPetState extends State<_SpriteAssistantPet>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  static const _clipTransitionDuration = Duration(milliseconds: 180);
  static const _idleFirstActionDelay = Duration(seconds: 8);
  static const _idleActionMinDelay = Duration(seconds: 7);
  static const _idleActionDelayRange = 6;

  late final AnimationController _timeline;
  late final AnimationController _transition;
  final math.Random _random = math.Random();
  late _PetClip _requestedClip;
  _PetClip? _clip;
  _PetClip? _previousClip;
  ui.Image? _image;
  ui.Image? _previousImage;
  int _previousFrame = 0;
  int? _previousNextFrame;
  double _previousFrameBlend = 0;
  int _loadGeneration = 0;
  int _warmGeneration = 0;
  bool _appResumed = true;
  bool _tickerEnabled = true;
  bool _active = true;
  Timer? _idleTimer;
  _PetClip? _idleOverride;
  String? _lastIdleActionKey;
  bool _idleFirstActionPending = true;
  late DateTime _nextLargeIdleAction;
  int? _pendingInteractionRevision;
  int? _activeInteractionRevision;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appResumed = switch (WidgetsBinding.instance.lifecycleState) {
      null || AppLifecycleState.resumed => true,
      _ => false,
    };
    _timeline = AnimationController(vsync: this);
    _transition = AnimationController(
      vsync: this,
      duration: _clipTransitionDuration,
      value: 1,
    )..addStatusListener(_handleTransitionStatus);
    _timeline.addStatusListener(_handleTimelineStatus);
    _nextLargeIdleAction = _futureLargeIdleAction();
    _requestedClip = _desiredClip;
    _loadClip(_requestedClip, animate: false);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _updateActive();
  }

  @override
  void didUpdateWidget(covariant _SpriteAssistantPet oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasIdle = _isIdleContext(oldWidget);
    final isIdle = _isIdleContext();
    final appearanceChanged = oldWidget.appearance != widget.appearance;
    final interactionStarted =
        widget.interaction != AssistantPetInteraction.none &&
        (oldWidget.interaction != widget.interaction ||
            oldWidget.interactionRevision != widget.interactionRevision);
    if (widget.interaction == AssistantPetInteraction.none) {
      _pendingInteractionRevision = null;
      _activeInteractionRevision = null;
    } else if (interactionStarted) {
      _pendingInteractionRevision = widget.interactionRevision;
      _activeInteractionRevision = null;
    }
    if (!isIdle) {
      _cancelIdleSchedule();
      _idleOverride = null;
      _idleFirstActionPending = true;
    } else if (!wasIdle || appearanceChanged) {
      _cancelIdleSchedule();
      _idleOverride = null;
      _idleFirstActionPending = true;
      _nextLargeIdleAction = _futureLargeIdleAction();
    }
    final next = _desiredClip;
    if (_requestedClip.key != next.key || _requestedClip.asset != next.asset) {
      _requestedClip = next;
      _loadClip(next, animate: true);
    } else if (interactionStarted) {
      // Replaying the same interaction gets its own smooth transition. This
      // also prevents the previous run from completing the new gesture.
      _loadClip(next, animate: true);
    }
    if (isIdle && _idleOverride == null && _clip?.isIdleRest == true) {
      _scheduleIdleAction();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appResumed = state == AppLifecycleState.resumed;
    _updateActive();
  }

  void _updateActive() => _setActive(_appResumed && _tickerEnabled);

  void _setActive(bool value) {
    if (_active == value) return;
    _active = value;
    if (_active) {
      if (_transition.value < 1) {
        _transition.forward();
      } else {
        _startTimeline();
      }
      if (_isIdleContext() && _idleOverride == null) {
        _scheduleIdleAction();
      }
    } else {
      _cancelIdleSchedule();
      _timeline.stop(canceled: false);
      _transition.stop(canceled: false);
    }
  }

  void _handleTimelineStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    final clip = _clip;
    if (clip?.isIdleAction == true && _isIdleContext()) {
      _idleOverride = null;
      final rest = _PetClips.idleRest(widget.appearance);
      _requestedClip = rest;
      unawaited(_loadClip(rest, animate: true));
      return;
    }
    final completedInteractionRevision = _pendingInteractionRevision;
    if (completedInteractionRevision != null &&
        _activeInteractionRevision == completedInteractionRevision &&
        widget.interaction != AssistantPetInteraction.none &&
        clip != null &&
        !clip.loop &&
        _requestedClip.key == clip.key &&
        _requestedClip.asset == clip.asset) {
      _pendingInteractionRevision = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            widget.interaction != AssistantPetInteraction.none &&
            widget.interactionRevision == completedInteractionRevision &&
            _activeInteractionRevision == completedInteractionRevision) {
          widget.onInteractionComplete?.call();
        }
      });
      return;
    }
    if (clip == null ||
        clip.loop ||
        widget.interaction != AssistantPetInteraction.none ||
        !_shouldSettleMode(widget.mode) ||
        _requestedClip.key != clip.key) {
      return;
    }
    final steady = _PetClips.steadyFor(
      appearance: widget.appearance,
      mode: widget.mode,
    );
    if (steady.key == clip.key) return;
    _requestedClip = steady;
    unawaited(_loadClip(steady, animate: true));
  }

  bool _shouldSettleMode(AssistantPetMode mode) => switch (mode) {
    AssistantPetMode.waking || AssistantPetMode.error => true,
    _ => false,
  };

  void _handleTransitionStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || _previousImage == null) return;
    _previousImage?.dispose();
    _previousImage = null;
    _previousClip = null;
    _previousFrame = 0;
    _previousNextFrame = null;
    _previousFrameBlend = 0;
    if (_active) _startTimeline();
    if (mounted) setState(() {});
  }

  Future<void> _loadClip(_PetClip next, {required bool animate}) async {
    final generation = ++_loadGeneration;
    try {
      final image = await _PetImageCache.instance.acquire(next.asset);
      if (!mounted || generation != _loadGeneration) {
        image.dispose();
        return;
      }
      final outgoing = _clip?.sampleAt(_timeline.value);
      _transition.stop(canceled: false);
      _previousImage?.dispose();
      _previousImage = animate ? _image : null;
      _previousClip = animate ? _clip : null;
      _previousFrame = animate ? outgoing?.frame ?? 0 : 0;
      _previousNextFrame = animate ? outgoing?.nextFrame : null;
      _previousFrameBlend = animate ? outgoing?.blend ?? 0 : 0;
      if (!animate) _image?.dispose();
      _image = image;
      _clip = next;
      final desired = _desiredClip;
      _activeInteractionRevision =
          widget.interaction != AssistantPetInteraction.none &&
              desired.key == next.key &&
              desired.asset == next.asset
          ? widget.interactionRevision
          : null;
      _timeline.stop(canceled: false);
      _timeline.value = 0;
      _transition.value = animate && _previousImage != null ? 0 : 1;
      if (_active) {
        if (_transition.value < 1) {
          _transition.forward();
        } else {
          _startTimeline();
        }
      }
      if (mounted) setState(() {});
      _scheduleWarmup(next);
      if (next.isIdleRest && _isIdleContext()) {
        _scheduleIdleAction();
      }
    } catch (error, stackTrace) {
      if (generation == _loadGeneration) {
        if (next.isIdleAction) {
          _idleOverride = null;
          final rest = _PetClips.idleRest(widget.appearance);
          _requestedClip = rest;
          if (_isIdleContext()) unawaited(_loadClip(rest, animate: true));
        } else {
          _requestedClip = _clip ?? next;
        }
      }
      debugPrint('加载宠物动画失败: ${next.asset}: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  void _startTimeline() {
    final clip = _clip;
    if (!_active || clip == null || clip.frameCount <= 1) return;
    _timeline.duration = clip.totalDuration;
    if (clip.loop) {
      _timeline.repeat();
    } else if (_timeline.value < 1) {
      _timeline.forward();
    }
  }

  DateTime _futureLargeIdleAction() =>
      DateTime.now().add(Duration(seconds: 50 + _random.nextInt(31)));

  bool _isIdleContext([_SpriteAssistantPet? source]) {
    final current = source ?? widget;
    return current.interactive &&
        current.appearance != AiPetAppearance.kuzai &&
        current.mode == AssistantPetMode.idle &&
        current.interaction == AssistantPetInteraction.none &&
        !current.dragging;
  }

  void _cancelIdleSchedule() {
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  void _scheduleIdleAction() {
    if (!_active || !_isIdleContext() || _idleOverride != null) return;
    if (_idleTimer != null) return;
    final delay = _idleFirstActionPending
        ? _idleFirstActionDelay
        : _idleActionMinDelay +
              Duration(seconds: _random.nextInt(_idleActionDelayRange));
    _idleFirstActionPending = false;
    _idleTimer = Timer(delay, _runIdleAction);
  }

  void _runIdleAction() {
    _idleTimer = null;
    if (!_active || !_isIdleContext()) return;
    final now = DateTime.now();
    final useLargeAction = !now.isBefore(_nextLargeIdleAction);
    var actions = useLargeAction
        ? _PetClips.largeIdleActions(widget.appearance)
        : _PetClips.idleActions(widget.appearance);
    if (actions.isEmpty && useLargeAction) {
      actions = _PetClips.idleActions(widget.appearance);
    }
    if (actions.isEmpty) {
      _scheduleIdleAction();
      return;
    }
    final candidates = actions.length == 1
        ? actions
        : actions.where((clip) => clip.key != _lastIdleActionKey).toList();
    final selected = candidates[_random.nextInt(candidates.length)];
    if (useLargeAction) _nextLargeIdleAction = _futureLargeIdleAction();
    _lastIdleActionKey = selected.key;
    _idleOverride = selected;
    _requestedClip = selected;
    unawaited(_loadClip(selected, animate: true));
  }

  void _scheduleWarmup(_PetClip clip) {
    final generation = ++_warmGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _warmGeneration) return;
      unawaited(
        _PetImageCache.instance.warm(
          _PetClips.warmupAssets(
            appearance: widget.appearance,
            mode: widget.mode,
            interaction: widget.interaction,
            dragging: widget.dragging,
            dragDirection: widget.dragDirection,
            currentAsset: clip.asset,
          ),
          shouldContinue: () => mounted && generation == _warmGeneration,
        ),
      );
    });
  }

  _PetClip get _desiredClip {
    if (_isIdleContext() && _idleOverride != null) return _idleOverride!;
    return _PetClips.resolve(
      appearance: widget.appearance,
      mode: widget.mode,
      interaction: widget.interaction,
      dragging: widget.dragging,
      dragDirection: widget.dragDirection,
    );
  }

  @override
  void dispose() {
    _loadGeneration++;
    _warmGeneration++;
    _cancelIdleSchedule();
    WidgetsBinding.instance.removeObserver(this);
    _timeline.removeStatusListener(_handleTimelineStatus);
    _timeline.dispose();
    _transition.dispose();
    _image?.dispose();
    _previousImage?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final semantics = Semantics(
      button: widget.interactive,
      label: '打开${widget.appearance.label} AI 助手',
      hint: widget.interactive ? '点击对话，拖动可移动位置，长按互动' : null,
      value: _semanticValue,
      onTap: widget.interactive ? widget.onTap : null,
      onLongPress: widget.interactive
          ? () => widget.onLongPressStart(
              LongPressStartDetails(localPosition: Offset(widget.size / 2, 0)),
            )
          : null,
      child: RepaintBoundary(
        child: SizedBox(
          width: widget.size * 1.12,
          height: widget.size,
          child: CustomPaint(
            key: ValueKey(
              'assistant-pet-clip-${_clip?.key ?? '${widget.appearance.value}-loading'}',
            ),
            painter: _SpritePetPainter(
              image: _image,
              clip: _clip,
              progress: _timeline,
              previousImage: _previousImage,
              previousClip: _previousClip,
              previousFrame: _previousFrame,
              previousNextFrame: _previousNextFrame,
              previousFrameBlend: _previousFrameBlend,
              transition: _transition,
            ),
          ),
        ),
      ),
    );
    if (!widget.interactive) return semantics;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onLongPressStart: widget.onLongPressStart,
      child: semantics,
    );
  }

  String get _semanticValue {
    if (widget.dragging) return '正在移动';
    if (widget.interaction == AssistantPetInteraction.wave) return '正在打招呼';
    if (widget.interaction == AssistantPetInteraction.petting) return '正在互动';
    return switch (widget.mode) {
      AssistantPetMode.idle => '空闲',
      AssistantPetMode.waking => '正在准备',
      AssistantPetMode.listening => '正在聆听',
      AssistantPetMode.thinking => '正在思考',
      AssistantPetMode.speaking => '正在回答',
      AssistantPetMode.textOnly => '等待文字输入',
      AssistantPetMode.paused => '已暂停聆听',
      AssistantPetMode.stopping => '正在告别',
      AssistantPetMode.error => '遇到问题',
    };
  }
}

class _SpritePetPainter extends CustomPainter {
  _SpritePetPainter({
    required this.image,
    required this.clip,
    required this.progress,
    required this.previousImage,
    required this.previousClip,
    required this.previousFrame,
    required this.previousNextFrame,
    required this.previousFrameBlend,
    required this.transition,
  }) : super(repaint: Listenable.merge([progress, transition]));

  final ui.Image? image;
  final _PetClip? clip;
  final Animation<double> progress;
  final ui.Image? previousImage;
  final _PetClip? previousClip;
  final int previousFrame;
  final int? previousNextFrame;
  final double previousFrameBlend;
  final Animation<double> transition;
  final Paint _paint = Paint()
    ..isAntiAlias = true
    ..filterQuality = FilterQuality.medium;

  @override
  void paint(Canvas canvas, Size size) {
    final transitionValue = Curves.easeInOutCubic.transform(transition.value);
    if (previousImage != null && previousClip != null && transitionValue < 1) {
      _paintSample(
        canvas,
        size,
        previousImage!,
        previousClip!,
        _PetFrameSample(
          frame: previousFrame,
          nextFrame: previousNextFrame,
          blend: previousFrameBlend,
        ),
        1 - transitionValue,
      );
    }
    final currentImage = image;
    final currentClip = clip;
    if (currentImage == null || currentClip == null) return;
    _paintSample(
      canvas,
      size,
      currentImage,
      currentClip,
      currentClip.sampleAt(progress.value),
      transitionValue,
    );
  }

  void _paintSample(
    Canvas canvas,
    Size size,
    ui.Image image,
    _PetClip clip,
    _PetFrameSample sample,
    double opacity,
  ) {
    final blend = sample.blend.clamp(0.0, 1.0).toDouble();
    _paintFrame(canvas, size, image, clip, sample.frame, opacity * (1 - blend));
    final nextFrame = sample.nextFrame;
    if (nextFrame != null && blend > 0) {
      _paintFrame(canvas, size, image, clip, nextFrame, opacity * blend);
    }
  }

  void _paintFrame(
    Canvas canvas,
    Size size,
    ui.Image image,
    _PetClip clip,
    int frame,
    double opacity,
  ) {
    final source = Rect.fromLTWH(
      frame * clip.frameWidth,
      0,
      clip.frameWidth,
      clip.frameHeight,
    );
    final scale = (size.height / clip.frameHeight).clamp(
      0.0,
      size.width / clip.frameWidth,
    );
    final destination = Rect.fromLTWH(
      (size.width - clip.frameWidth * scale) / 2,
      (size.height - clip.frameHeight * scale) / 2,
      clip.frameWidth * scale,
      clip.frameHeight * scale,
    );
    _paint.color = Color.fromRGBO(255, 255, 255, opacity.clamp(0, 1));
    canvas.drawImageRect(image, source, destination, _paint);
  }

  @override
  bool shouldRepaint(covariant _SpritePetPainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.clip != clip ||
      oldDelegate.previousImage != previousImage ||
      oldDelegate.previousClip != previousClip ||
      oldDelegate.previousFrame != previousFrame ||
      oldDelegate.previousNextFrame != previousNextFrame ||
      oldDelegate.previousFrameBlend != previousFrameBlend;
}

class _PetImageCache {
  _PetImageCache._({required this.maxEntries});

  static final instance = _PetImageCache._(maxEntries: 8);

  final int maxEntries;
  final Map<String, _PetImageCacheEntry> _entries = {};
  int _clock = 0;

  Future<ui.Image> acquire(String asset) => _acquire(asset, retry: true);

  Future<ui.Image> _acquire(String asset, {required bool retry}) async {
    final entry = _entryFor(asset);
    entry.pins++;
    try {
      // Reuse the published image immediately instead of waiting on the
      // original decode future during a later appearance switch.
      final image = entry.image ?? await entry.future;
      try {
        return image.clone();
      } catch (_) {
        // An invalid native handle must not remain published. Evict this
        // exact entry, release it when still owned here, and retry once.
        if (identical(_entries[asset], entry)) {
          _entries.remove(asset);
          final publishedImage = entry.image;
          entry.image = null;
          try {
            publishedImage?.dispose();
          } catch (_) {
            // The clone failure may already mean the handle was disposed.
          }
        }
      }
    } finally {
      entry.pins--;
      _trim();
    }
    if (retry) return _acquire(asset, retry: false);
    throw StateError('无法克隆宠物素材: $asset');
  }

  Future<void> warm(
    Iterable<String> assets, {
    required bool Function() shouldContinue,
  }) async {
    for (final asset in assets.toSet()) {
      if (!shouldContinue()) return;
      final entry = _entryFor(asset);
      entry.pins++;
      try {
        if (entry.image == null) await entry.future;
      } catch (_) {
        // The foreground load reports failures. Warmup remains best effort.
      } finally {
        entry.pins--;
        _trim();
      }
    }
  }

  _PetImageCacheEntry _entryFor(String asset) {
    final cached = _entries[asset];
    if (cached != null) {
      cached.lastUsed = ++_clock;
      return cached;
    }
    late final _PetImageCacheEntry entry;
    entry = _PetImageCacheEntry(_decode(asset), ++_clock);
    _entries[asset] = entry;
    unawaited(
      entry.future.then<void>(
        (image) {
          if (identical(_entries[asset], entry)) {
            entry.image = image;
            _trim();
          } else {
            image.dispose();
          }
        },
        onError: (Object _, StackTrace __) {
          if (identical(_entries[asset], entry)) _entries.remove(asset);
        },
      ),
    );
    return entry;
  }

  Future<ui.Image> _decode(String asset) async {
    ui.Codec? codec;
    try {
      final data = await rootBundle.load(asset);
      codec = await ui.instantiateImageCodec(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      final frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec?.dispose();
    }
  }

  void _trim() {
    while (_entries.length > maxEntries) {
      MapEntry<String, _PetImageCacheEntry>? oldest;
      for (final candidate in _entries.entries) {
        if (candidate.value.image == null || candidate.value.pins > 0) continue;
        if (oldest == null ||
            candidate.value.lastUsed < oldest.value.lastUsed) {
          oldest = candidate;
        }
      }
      if (oldest == null) return;
      _entries.remove(oldest.key);
      oldest.value.image?.dispose();
    }
  }
}

class _PetImageCacheEntry {
  _PetImageCacheEntry(this.future, this.lastUsed);

  final Future<ui.Image> future;
  ui.Image? image;
  int lastUsed;
  int pins = 0;
}

class _PetClip {
  const _PetClip({
    required this.key,
    required this.asset,
    required this.frameDurations,
    this.frameOrder,
    this.frameBlendFraction = 0.42,
    this.maxFrameBlendMilliseconds = 90,
    this.loop = true,
    this.idleRest = false,
    this.idleAction = false,
  }) : assert(frameBlendFraction >= 0 && frameBlendFraction <= 1),
       assert(maxFrameBlendMilliseconds >= 0);

  final String key;
  final String asset;
  final List<int> frameDurations;
  final List<int>? frameOrder;
  final double frameBlendFraction;
  final int maxFrameBlendMilliseconds;
  final bool loop;
  final bool idleRest;
  final bool idleAction;

  int get frameCount => frameDurations.length;

  bool get isIdleRest => idleRest;
  bool get isIdleAction => idleAction;

  double get frameWidth => 256;
  double get frameHeight => 256;
  Duration get totalDuration => Duration(
    milliseconds: frameDurations.fold<int>(0, (sum, value) => sum + value),
  );

  _PetFrameSample sampleAt(double progress) {
    assert(frameDurations.isNotEmpty);
    assert(frameOrder == null || frameOrder!.length == frameDurations.length);
    if (frameCount == 1) {
      return _PetFrameSample(frame: _sourceFrameAt(0));
    }
    final total = totalDuration.inMilliseconds;
    final normalized = progress.clamp(0.0, 1.0).toDouble();
    final elapsed = normalized >= 1 ? total : (normalized * total).floor();
    var cursor = 0;
    var step = frameCount - 1;
    var stepStart = total - frameDurations.last;
    for (var index = 0; index < frameDurations.length; index++) {
      final start = cursor;
      cursor += frameDurations[index];
      if (elapsed < cursor) {
        step = index;
        stepStart = start;
        break;
      }
    }
    final nextStep = step + 1 < frameCount ? step + 1 : (loop ? 0 : null);
    if (nextStep == null) {
      return _PetFrameSample(frame: _sourceFrameAt(step));
    }
    final duration = frameDurations[step];
    final blendDuration = math.min(
      maxFrameBlendMilliseconds,
      (duration * frameBlendFraction).round(),
    );
    if (blendDuration <= 0) {
      return _PetFrameSample(frame: _sourceFrameAt(step));
    }
    final localElapsed = (elapsed - stepStart).clamp(0, duration);
    final blendStart = duration - blendDuration;
    if (localElapsed <= blendStart) {
      return _PetFrameSample(frame: _sourceFrameAt(step));
    }
    final rawBlend = (localElapsed - blendStart) / blendDuration;
    return _PetFrameSample(
      frame: _sourceFrameAt(step),
      nextFrame: _sourceFrameAt(nextStep),
      blend: Curves.easeInOutCubic.transform(rawBlend.clamp(0.0, 1.0)),
    );
  }

  int _sourceFrameAt(int step) => frameOrder?[step] ?? step;
}

class _PetFrameSample {
  const _PetFrameSample({required this.frame, this.nextFrame, this.blend = 0});

  final int frame;
  final int? nextFrame;
  final double blend;
}

abstract final class _PetClips {
  static const _moomew = <String, _PetClip>{
    'rest': _PetClip(
      key: 'moomew-rest',
      asset: 'assets/pets/moomew/rest.webp',
      frameDurations: [1000],
      idleRest: true,
      loop: false,
    ),
    'idle-focus': _PetClip(
      key: 'moomew-idle-focus',
      asset: 'assets/pets/moomew/idle.webp',
      frameOrder: [0, 1, 0, 4, 5, 4, 0],
      frameDurations: [360, 320, 320, 360, 520, 360, 520],
      loop: false,
      idleAction: true,
    ),
    'idle-blink': _PetClip(
      key: 'moomew-idle-blink',
      asset: 'assets/pets/moomew/idle-blink.webp',
      frameDurations: [220, 180, 520],
      loop: false,
      idleAction: true,
    ),
    'idle-glance': _PetClip(
      key: 'moomew-idle-glance',
      asset: 'assets/pets/moomew/idle-glance.webp',
      frameDurations: [240, 320, 520],
      loop: false,
      idleAction: true,
    ),
    'wave': _PetClip(
      key: 'moomew-wave',
      asset: 'assets/pets/moomew/waving.webp',
      frameOrder: [1, 0, 3],
      frameDurations: [180, 420, 360],
      loop: false,
    ),
    'jump': _PetClip(
      key: 'moomew-jump',
      asset: 'assets/pets/moomew/jumping.webp',
      // Enter and leave on the upright frame so a tap never cuts into the
      // crouched pose. The middle frames retain the source jump motion.
      frameOrder: [0, 1, 2, 3, 4, 0],
      frameDurations: [220, 150, 150, 150, 180, 420],
      loop: false,
    ),
    'error': _PetClip(
      key: 'moomew-error',
      asset: 'assets/pets/moomew/failed.webp',
      frameOrder: [0, 1, 2],
      frameDurations: [220, 280, 700],
      loop: false,
    ),
    'wait': _PetClip(
      key: 'moomew-wait',
      asset: 'assets/pets/moomew/waiting.webp',
      frameOrder: [1, 0, 1, 2, 1],
      frameDurations: [500, 650, 420, 900, 620],
    ),
    'wait-still': _PetClip(
      key: 'moomew-wait-still',
      asset: 'assets/pets/moomew/waiting.webp',
      frameOrder: [1],
      frameDurations: [1000],
      loop: false,
    ),
    'review': _PetClip(
      key: 'moomew-review',
      asset: 'assets/pets/moomew/review.webp',
      frameOrder: [0, 1, 0],
      frameDurations: [520, 620, 520],
    ),
    'speak': _PetClip(
      key: 'moomew-speak',
      asset: 'assets/pets/moomew/waving.webp',
      // A low-energy loop for long TTS replies. Both ends are the laptop
      // pose, so looping and state changes do not introduce a paw pop.
      frameOrder: [1, 0, 3, 0, 1],
      frameDurations: [520, 180, 520, 180, 620],
    ),
    'error-hold': _PetClip(
      key: 'moomew-error-hold',
      asset: 'assets/pets/moomew/failed.webp',
      frameOrder: [2],
      frameDurations: [1000],
      loop: false,
    ),
    'drag-left': _PetClip(
      key: 'moomew-drag-left',
      asset: 'assets/pets/moomew/running-left.webp',
      frameOrder: [0, 1],
      frameDurations: [150, 150],
    ),
    'drag-right': _PetClip(
      key: 'moomew-drag-right',
      asset: 'assets/pets/moomew/running-right.webp',
      frameOrder: [0, 1],
      frameDurations: [150, 150],
    ),
  };

  static const _xiaohei = <String, _PetClip>{
    'rest': _PetClip(
      key: 'xiaohei-rest',
      asset: 'assets/pets/xiaohei/rest.webp',
      frameDurations: [1000],
      idleRest: true,
      loop: false,
    ),
    'idle-glance': _PetClip(
      key: 'xiaohei-idle-glance',
      asset: 'assets/pets/xiaohei/idle-glance.webp',
      frameDurations: [260, 360, 520],
      loop: false,
      idleAction: true,
    ),
    'idle-tilt': _PetClip(
      key: 'xiaohei-idle-tilt',
      asset: 'assets/pets/xiaohei/idle-tilt.webp',
      frameDurations: [260, 420, 520],
      loop: false,
      idleAction: true,
    ),
    'idle-loop': _PetClip(
      key: 'xiaohei-idle-loop',
      asset: 'assets/pets/xiaohei/idle.webp',
      frameOrder: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0],
      frameDurations: [
        520,
        110,
        110,
        110,
        110,
        110,
        110,
        110,
        110,
        150,
        110,
        110,
        110,
        110,
        110,
        110,
        110,
        110,
        620,
      ],
    ),
    'idle-look': _PetClip(
      key: 'xiaohei-idle-look',
      asset: 'assets/pets/xiaohei/idle.webp',
      frameOrder: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0],
      frameDurations: [
        240,
        130,
        130,
        130,
        130,
        130,
        130,
        130,
        130,
        180,
        130,
        130,
        130,
        130,
        130,
        130,
        130,
        130,
        480,
      ],
      loop: false,
      idleAction: true,
    ),
    'text-wait': _PetClip(
      key: 'xiaohei-text-wait',
      asset: 'assets/pets/xiaohei/idle-tilt.webp',
      frameOrder: [0, 1],
      frameDurations: [260, 1000],
      loop: false,
    ),
    'error-shake': _PetClip(
      key: 'xiaohei-error-shake',
      asset: 'assets/pets/xiaohei/idle.webp',
      frameOrder: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0],
      frameDurations: [
        180,
        120,
        120,
        120,
        120,
        120,
        120,
        120,
        120,
        160,
        120,
        120,
        120,
        120,
        120,
        120,
        120,
        120,
        700,
      ],
      loop: false,
    ),
    'error-hold': _PetClip(
      key: 'xiaohei-error-hold',
      asset: 'assets/pets/xiaohei/idle.webp',
      frameOrder: [0],
      frameDurations: [1000],
      loop: false,
    ),
    'guitar': _PetClip(
      key: 'xiaohei-guitar',
      asset: 'assets/pets/xiaohei/guitar.webp',
      // Keep a complete strum cycle in a loop. The mirrored return frames
      // avoid the visible jump from the last source frame back to frame 0.
      frameOrder: [0, 1, 2, 3, 4, 5, 4, 3, 2, 1, 0],
      frameDurations: [180, 140, 140, 160, 220, 300, 220, 160, 140, 140, 520],
    ),
    'groom': _PetClip(
      key: 'xiaohei-groom',
      asset: 'assets/pets/xiaohei/groom.webp',
      frameOrder: [0, 1, 2, 3, 4, 5, 6, 7, 6, 5, 4, 3, 2, 1, 0],
      frameDurations: [
        120,
        100,
        100,
        100,
        100,
        100,
        100,
        140,
        100,
        100,
        100,
        100,
        100,
        100,
        350,
      ],
      loop: false,
    ),
    'idle-groom': _PetClip(
      key: 'xiaohei-idle-groom',
      asset: 'assets/pets/xiaohei/groom.webp',
      frameOrder: [0, 1, 2, 3, 4, 5, 6, 7, 6, 5, 4, 3, 2, 1, 0],
      frameDurations: [
        180,
        120,
        120,
        120,
        120,
        120,
        120,
        180,
        120,
        120,
        120,
        120,
        120,
        120,
        480,
      ],
      loop: false,
      idleAction: true,
    ),
    'bye': _PetClip(
      key: 'xiaohei-bye',
      asset: 'assets/pets/xiaohei/bye.webp',
      frameDurations: [
        100,
        100,
        100,
        100,
        100,
        100,
        100,
        100,
        100,
        100,
        100,
        100,
        100,
        100,
        100,
        400,
      ],
      loop: false,
    ),
    'play': _PetClip(
      key: 'xiaohei-play',
      asset: 'assets/pets/xiaohei/play.webp',
      frameOrder: [0, 1, 2, 3, 4, 3, 2, 1, 0],
      frameDurations: [110, 110, 110, 110, 140, 110, 110, 110, 300],
      loop: false,
    ),
    'drag': _PetClip(
      key: 'xiaohei-drag',
      asset: 'assets/pets/xiaohei/play.webp',
      frameOrder: [0, 1, 2, 3, 4, 3, 2, 1],
      frameDurations: [120, 120, 120, 120, 140, 120, 120, 120],
    ),
    'eat': _PetClip(
      key: 'xiaohei-eat',
      asset: 'assets/pets/xiaohei/eat.webp',
      frameDurations: [
        70,
        70,
        70,
        70,
        70,
        70,
        70,
        70,
        70,
        70,
        70,
        70,
        70,
        70,
        70,
        70,
        70,
        70,
        70,
        70,
        70,
        70,
      ],
      loop: false,
    ),
  };

  static const _whale = <String, _PetClip>{
    'rest': _PetClip(
      key: 'whale-rest',
      asset: 'assets/pets/whale_girl/rest.webp',
      frameDurations: [1000],
      idleRest: true,
      loop: false,
    ),
    'idle-blink': _PetClip(
      key: 'whale-idle-blink',
      asset: 'assets/pets/whale_girl/idle-blink.webp',
      frameDurations: [220, 180, 520],
      // The source contains a fully closed middle frame. A shorter blend
      // window prevents it from reading as a half blink on slower displays.
      frameBlendFraction: 0.22,
      maxFrameBlendMilliseconds: 48,
      loop: false,
      idleAction: true,
    ),
    'idle-drowsy': _PetClip(
      key: 'whale-idle-drowsy',
      asset: 'assets/pets/whale_girl/idle.webp',
      frameOrder: [0, 2, 1, 2, 0],
      frameDurations: [320, 160, 220, 180, 560],
      loop: false,
      idleAction: true,
    ),
    'working': _PetClip(
      key: 'whale-working',
      asset: 'assets/pets/whale_girl/working.webp',
      frameOrder: [0, 1, 2, 1, 0],
      frameDurations: [420, 360, 420, 360, 540],
    ),
    'celebrate': _PetClip(
      key: 'whale-celebrate',
      asset: 'assets/pets/whale_girl/celebrate.webp',
      frameDurations: [250, 250, 250],
      loop: false,
    ),
    'error': _PetClip(
      key: 'whale-error',
      asset: 'assets/pets/whale_girl/error.webp',
      frameDurations: [240, 700],
      loop: false,
    ),
    'error-hold': _PetClip(
      key: 'whale-error-hold',
      asset: 'assets/pets/whale_girl/error.webp',
      frameOrder: [1],
      frameDurations: [1000],
      loop: false,
    ),
    'disappointed': _PetClip(
      key: 'whale-disappointed',
      asset: 'assets/pets/whale_girl/disappointed.webp',
      frameDurations: [500, 500],
      loop: false,
    ),
    'joy': _PetClip(
      key: 'whale-joy',
      asset: 'assets/pets/whale_girl/joy.webp',
      frameOrder: [0, 1, 0],
      frameDurations: [260, 260, 360],
      loop: false,
    ),
    'drag': _PetClip(
      key: 'whale-drag',
      asset: 'assets/pets/whale_girl/drag.webp',
      frameDurations: [1000],
    ),
    'sleep': _PetClip(
      key: 'whale-sleep',
      asset: 'assets/pets/whale_girl/sleep.webp',
      frameDurations: [1000, 1000],
      loop: false,
    ),
    'wake': _PetClip(
      key: 'whale-wake',
      asset: 'assets/pets/whale_girl/wake.webp',
      frameOrder: [1, 0, 1],
      frameDurations: [360, 480, 620],
      loop: false,
    ),
    'welcome': _PetClip(
      key: 'whale-welcome',
      asset: 'assets/pets/whale_girl/welcome.webp',
      frameOrder: [0, 1, 0],
      frameDurations: [260, 260, 360],
      loop: false,
    ),
    'think': _PetClip(
      key: 'whale-think',
      asset: 'assets/pets/whale_girl/think.webp',
      frameDurations: [1000],
    ),
    'wait': _PetClip(
      key: 'whale-wait',
      asset: 'assets/pets/whale_girl/wait.webp',
      frameDurations: [1000],
    ),
  };

  static _PetClip resolve({
    required AiPetAppearance appearance,
    required AssistantPetMode mode,
    required AssistantPetInteraction interaction,
    required bool dragging,
    required AssistantPetDragDirection dragDirection,
  }) {
    return switch (appearance) {
      AiPetAppearance.moomew => _moomewClip(
        mode,
        interaction,
        dragging,
        dragDirection,
      ),
      AiPetAppearance.xiaohei => _xiaoheiClip(mode, interaction, dragging),
      AiPetAppearance.whaleGirl => _whaleClip(mode, interaction, dragging),
      AiPetAppearance.kuzai => throw StateError(
        'Kuzai uses its vector painter',
      ),
    };
  }

  static _PetClip idleRest(AiPetAppearance appearance) => switch (appearance) {
    AiPetAppearance.moomew => _moomew['rest']!,
    AiPetAppearance.xiaohei => _xiaohei['rest']!,
    AiPetAppearance.whaleGirl => _whale['rest']!,
    AiPetAppearance.kuzai => throw StateError('Kuzai uses its vector painter'),
  };

  /// Stable posture used when a one-shot waking or error animation finishes
  /// before the controller publishes its next state.
  static _PetClip steadyFor({
    required AiPetAppearance appearance,
    required AssistantPetMode mode,
  }) => switch (appearance) {
    AiPetAppearance.moomew => switch (mode) {
      AssistantPetMode.waking => _moomew['wait-still']!,
      AssistantPetMode.error => _moomew['error-hold']!,
      _ => _moomew['rest']!,
    },
    AiPetAppearance.xiaohei => switch (mode) {
      AssistantPetMode.waking => _xiaohei['idle-loop']!,
      AssistantPetMode.error => _xiaohei['error-hold']!,
      _ => _xiaohei['rest']!,
    },
    AiPetAppearance.whaleGirl => switch (mode) {
      AssistantPetMode.waking => _whale['wait']!,
      AssistantPetMode.error => _whale['error-hold']!,
      _ => _whale['rest']!,
    },
    AiPetAppearance.kuzai => throw StateError('Kuzai uses its vector painter'),
  };

  static List<_PetClip> idleActions(AiPetAppearance appearance) =>
      switch (appearance) {
        AiPetAppearance.moomew => [
          _moomew['idle-blink']!,
          _moomew['idle-glance']!,
        ],
        AiPetAppearance.xiaohei => [
          _xiaohei['idle-glance']!,
          _xiaohei['idle-tilt']!,
        ],
        AiPetAppearance.whaleGirl => [_whale['idle-blink']!],
        AiPetAppearance.kuzai => const [],
      };

  static List<_PetClip> largeIdleActions(AiPetAppearance appearance) =>
      switch (appearance) {
        AiPetAppearance.moomew => [_moomew['idle-focus']!],
        AiPetAppearance.xiaohei => [
          _xiaohei['idle-look']!,
          _xiaohei['idle-groom']!,
        ],
        AiPetAppearance.whaleGirl => [_whale['idle-drowsy']!],
        AiPetAppearance.kuzai => const [],
      };

  static Iterable<String> warmupAssets({
    required AiPetAppearance appearance,
    required AssistantPetMode mode,
    required AssistantPetInteraction interaction,
    required bool dragging,
    required AssistantPetDragDirection dragDirection,
    required String currentAsset,
  }) {
    if (appearance == AiPetAppearance.kuzai) return const [];
    if (dragging || interaction != AssistantPetInteraction.none) {
      final baseClip = resolve(
        appearance: appearance,
        mode: mode,
        interaction: AssistantPetInteraction.none,
        dragging: false,
        dragDirection: dragDirection,
      );
      return baseClip.asset == currentAsset ? const [] : [baseClip.asset];
    }

    final clips = switch (appearance) {
      AiPetAppearance.moomew => _clipsForKeys(_moomew, switch (mode) {
        AssistantPetMode.idle => const [
          'rest',
          'wave',
          'jump',
          'drag-left',
          'drag-right',
          'idle-blink',
          'idle-glance',
          'idle-focus',
        ],
        AssistantPetMode.waking => const ['wait-still'],
        AssistantPetMode.listening => const ['review', 'wait-still'],
        AssistantPetMode.textOnly || AssistantPetMode.paused => const ['rest'],
        AssistantPetMode.thinking => const ['speak', 'wait', 'error'],
        AssistantPetMode.speaking => const ['wait', 'wave'],
        AssistantPetMode.stopping => const ['wave', 'rest'],
        AssistantPetMode.error => const ['error', 'error-hold', 'rest'],
      }),
      AiPetAppearance.xiaohei => _clipsForKeys(_xiaohei, switch (mode) {
        AssistantPetMode.idle => const [
          'rest',
          'play',
          'groom',
          'drag',
          'idle-glance',
          'idle-tilt',
          'idle-look',
        ],
        AssistantPetMode.waking => const ['idle-loop'],
        AssistantPetMode.listening => const ['text-wait'],
        AssistantPetMode.textOnly ||
        AssistantPetMode.thinking => const ['guitar', 'error-shake'],
        AssistantPetMode.paused => const ['idle-loop'],
        AssistantPetMode.speaking => const ['guitar', 'idle-loop'],
        AssistantPetMode.stopping => const ['bye', 'rest'],
        AssistantPetMode.error => const ['error-shake', 'error-hold', 'rest'],
      }),
      AiPetAppearance.whaleGirl => _clipsForKeys(_whale, switch (mode) {
        AssistantPetMode.idle => const [
          'rest',
          'welcome',
          'joy',
          'drag',
          'idle-blink',
          'idle-drowsy',
        ],
        AssistantPetMode.waking => const ['wait'],
        AssistantPetMode.listening ||
        AssistantPetMode.textOnly => const ['think'],
        AssistantPetMode.paused => const ['wait'],
        AssistantPetMode.thinking => const ['working', 'error'],
        AssistantPetMode.speaking => const ['wait', 'welcome'],
        AssistantPetMode.stopping => const ['welcome', 'rest'],
        AssistantPetMode.error => const ['error', 'error-hold', 'rest'],
      }),
      AiPetAppearance.kuzai => const <_PetClip>[],
    };
    final interactionClips = switch (appearance) {
      AiPetAppearance.moomew => [_moomew['wave']!, _moomew['jump']!],
      AiPetAppearance.xiaohei => [_xiaohei['play']!, _xiaohei['groom']!],
      AiPetAppearance.whaleGirl => [_whale['welcome']!, _whale['joy']!],
      AiPetAppearance.kuzai => const <_PetClip>[],
    };
    return <_PetClip>[
      ...clips,
      ...interactionClips,
    ].map((clip) => clip.asset).toSet().where((asset) => asset != currentAsset);
  }

  static List<_PetClip> _clipsForKeys(
    Map<String, _PetClip> clips,
    List<String> keys,
  ) => keys.map((key) => clips[key]!).toList(growable: false);

  static _PetClip _moomewClip(
    AssistantPetMode mode,
    AssistantPetInteraction interaction,
    bool dragging,
    AssistantPetDragDirection dragDirection,
  ) {
    if (dragging && dragDirection != AssistantPetDragDirection.none) {
      return dragDirection == AssistantPetDragDirection.right
          ? _moomew['drag-right']!
          : _moomew['drag-left']!;
    }
    if (interaction == AssistantPetInteraction.petting) return _moomew['jump']!;
    if (interaction == AssistantPetInteraction.wave) return _moomew['wave']!;
    return switch (mode) {
      AssistantPetMode.waking => _moomew['jump']!,
      AssistantPetMode.listening => _moomew['wait']!,
      AssistantPetMode.textOnly => _moomew['wait-still']!,
      AssistantPetMode.paused => _moomew['rest']!,
      AssistantPetMode.thinking => _moomew['review']!,
      AssistantPetMode.speaking => _moomew['speak']!,
      AssistantPetMode.stopping => _moomew['wave']!,
      AssistantPetMode.error => _moomew['error']!,
      AssistantPetMode.idle => _moomew['rest']!,
    };
  }

  static _PetClip _xiaoheiClip(
    AssistantPetMode mode,
    AssistantPetInteraction interaction,
    bool dragging,
  ) {
    if (dragging) return _xiaohei['drag']!;
    if (interaction == AssistantPetInteraction.petting) {
      return _xiaohei['groom']!;
    }
    if (interaction == AssistantPetInteraction.wave) return _xiaohei['play']!;
    return switch (mode) {
      AssistantPetMode.waking => _xiaohei['play']!,
      AssistantPetMode.thinking => _xiaohei['text-wait']!,
      AssistantPetMode.speaking => _xiaohei['guitar']!,
      AssistantPetMode.stopping => _xiaohei['bye']!,
      AssistantPetMode.error => _xiaohei['error-shake']!,
      AssistantPetMode.listening => _xiaohei['idle-loop']!,
      AssistantPetMode.textOnly => _xiaohei['text-wait']!,
      AssistantPetMode.paused => _xiaohei['rest']!,
      AssistantPetMode.idle => _xiaohei['rest']!,
    };
  }

  static _PetClip _whaleClip(
    AssistantPetMode mode,
    AssistantPetInteraction interaction,
    bool dragging,
  ) {
    if (dragging) return _whale['drag']!;
    if (interaction == AssistantPetInteraction.petting) return _whale['joy']!;
    if (interaction == AssistantPetInteraction.wave) return _whale['welcome']!;
    return switch (mode) {
      AssistantPetMode.waking => _whale['wake']!,
      AssistantPetMode.listening ||
      AssistantPetMode.textOnly => _whale['wait']!,
      AssistantPetMode.paused => _whale['rest']!,
      AssistantPetMode.thinking => _whale['think']!,
      AssistantPetMode.speaking => _whale['working']!,
      AssistantPetMode.stopping => _whale['welcome']!,
      AssistantPetMode.error => _whale['error']!,
      AssistantPetMode.idle => _whale['rest']!,
    };
  }
}
