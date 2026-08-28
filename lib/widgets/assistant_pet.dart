import 'dart:async';
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
    this.interactive = true,
  });

  final AiPetAppearance appearance;
  final double size;
  final AssistantPetMode mode;
  final AssistantPetInteraction interaction;
  final VoidCallback onTap;
  final GestureLongPressStartCallback onLongPressStart;
  final bool dragging;
  final bool interactive;

  @override
  Widget build(BuildContext context) {
    if (appearance == AiPetAppearance.kuzai) {
      return KuzaiPet(
        size: size,
        mode: _kuzaiMode,
        onTap: onTap,
        onLongPressStart: onLongPressStart,
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
      interactive: interactive,
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
    required this.interactive,
  });

  final AiPetAppearance appearance;
  final double size;
  final AssistantPetMode mode;
  final AssistantPetInteraction interaction;
  final VoidCallback onTap;
  final GestureLongPressStartCallback onLongPressStart;
  final bool dragging;
  final bool interactive;

  @override
  State<_SpriteAssistantPet> createState() => _SpriteAssistantPetState();
}

class _SpriteAssistantPetState extends State<_SpriteAssistantPet>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  late final AnimationController _timeline;
  late final AnimationController _transition;
  late _PetClip _requestedClip;
  _PetClip? _clip;
  _PetClip? _previousClip;
  ui.Image? _image;
  ui.Image? _previousImage;
  int _previousFrame = 0;
  int _loadGeneration = 0;
  int _warmGeneration = 0;
  bool _appResumed = true;
  bool _tickerEnabled = true;
  bool _active = true;

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
      duration: const Duration(milliseconds: 140),
      value: 1,
    )..addStatusListener(_handleTransitionStatus);
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
    final next = _desiredClip;
    if (_requestedClip.key != next.key || _requestedClip.asset != next.asset) {
      _requestedClip = next;
      _loadClip(next, animate: true);
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
      _startTimeline();
      if (_transition.value < 1) _transition.forward();
    } else {
      _timeline.stop(canceled: false);
      _transition.stop(canceled: false);
    }
  }

  void _handleTransitionStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || _previousImage == null) return;
    _previousImage?.dispose();
    _previousImage = null;
    _previousClip = null;
    _previousFrame = 0;
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
      final outgoingFrame = _clip?.frameAt(_timeline.value) ?? 0;
      _transition.stop(canceled: false);
      _previousImage?.dispose();
      _previousImage = animate ? _image : null;
      _previousClip = animate ? _clip : null;
      _previousFrame = animate ? outgoingFrame : 0;
      if (!animate) _image?.dispose();
      _image = image;
      _clip = next;
      _timeline.stop();
      _timeline.value = 0;
      _transition.value = animate && _previousImage != null ? 0 : 1;
      if (_active) {
        _startTimeline();
        if (_transition.value < 1) _transition.forward();
      }
      if (mounted) setState(() {});
      _scheduleWarmup(next);
    } catch (error, stackTrace) {
      if (generation == _loadGeneration) _requestedClip = _clip ?? next;
      debugPrint('加载宠物动画失败: ${next.asset}: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  void _startTimeline() {
    final clip = _clip;
    if (!_active || clip == null || clip.frameCount <= 1) return;
    _timeline.duration = clip.totalDuration;
    _timeline.repeat();
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
            currentAsset: clip.asset,
          ),
          shouldContinue: () => mounted && generation == _warmGeneration,
        ),
      );
    });
  }

  _PetClip get _desiredClip => _PetClips.resolve(
    appearance: widget.appearance,
    mode: widget.mode,
    interaction: widget.interaction,
    dragging: widget.dragging,
  );

  @override
  void dispose() {
    _loadGeneration++;
    _warmGeneration++;
    WidgetsBinding.instance.removeObserver(this);
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
    required this.transition,
  }) : super(repaint: Listenable.merge([progress, transition]));

  final ui.Image? image;
  final _PetClip? clip;
  final Animation<double> progress;
  final ui.Image? previousImage;
  final _PetClip? previousClip;
  final int previousFrame;
  final Animation<double> transition;
  final Paint _paint = Paint()
    ..isAntiAlias = true
    ..filterQuality = FilterQuality.medium;

  @override
  void paint(Canvas canvas, Size size) {
    final transitionValue = transition.value;
    if (previousImage != null && previousClip != null && transitionValue < 1) {
      _paintFrame(
        canvas,
        size,
        previousImage!,
        previousClip!,
        previousFrame,
        1 - transitionValue,
      );
    }
    final currentImage = image;
    final currentClip = clip;
    if (currentImage == null || currentClip == null) return;
    _paintFrame(
      canvas,
      size,
      currentImage,
      currentClip,
      currentClip.frameAt(progress.value),
      transitionValue,
    );
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
    final scale = (size.width / clip.frameWidth).clamp(
      0.0,
      size.height / clip.frameHeight,
    );
    final destination = Rect.fromLTWH(
      (size.width - clip.frameWidth * scale) / 2,
      size.height - clip.frameHeight * scale,
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
      oldDelegate.previousFrame != previousFrame;
}

class _PetImageCache {
  _PetImageCache._({required this.maxEntries});

  static final instance = _PetImageCache._(maxEntries: 6);

  final int maxEntries;
  final Map<String, _PetImageCacheEntry> _entries = {};
  int _clock = 0;

  Future<ui.Image> acquire(String asset) async {
    final entry = _entryFor(asset);
    entry.pins++;
    try {
      final image = await entry.future;
      return image.clone();
    } finally {
      entry.pins--;
      _trim();
    }
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
        await entry.future;
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
      codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
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
  });

  final String key;
  final String asset;
  final List<int> frameDurations;

  int get frameCount => frameDurations.length;

  double get frameWidth => 256;
  double get frameHeight => 256;
  Duration get totalDuration => Duration(
    milliseconds: frameDurations.fold<int>(0, (sum, value) => sum + value),
  );

  int frameAt(double progress) {
    if (frameCount == 1) return 0;
    final total = totalDuration.inMilliseconds;
    final elapsed = (progress.clamp(0.0, 1.0) * total).floor();
    var cursor = 0;
    for (var index = 0; index < frameDurations.length; index++) {
      cursor += frameDurations[index];
      if (elapsed < cursor) return index;
    }
    return frameCount - 1;
  }
}

abstract final class _PetClips {
  static const _moomew = <String, _PetClip>{
    'idle': _PetClip(
      key: 'moomew-idle',
      asset: 'assets/pets/moomew/idle.webp',
      frameDurations: [280, 110, 110, 140, 140, 320],
    ),
    'wave': _PetClip(
      key: 'moomew-wave',
      asset: 'assets/pets/moomew/waving.webp',
      frameDurations: [140, 140, 140, 280],
    ),
    'jump': _PetClip(
      key: 'moomew-jump',
      asset: 'assets/pets/moomew/jumping.webp',
      frameDurations: [140, 140, 140, 140, 280],
    ),
    'error': _PetClip(
      key: 'moomew-error',
      asset: 'assets/pets/moomew/failed.webp',
      frameDurations: [140, 140, 140, 140, 140, 140, 140, 240],
    ),
    'wait': _PetClip(
      key: 'moomew-wait',
      asset: 'assets/pets/moomew/waiting.webp',
      frameDurations: [150, 150, 150, 150, 150, 260],
    ),
    'review': _PetClip(
      key: 'moomew-review',
      asset: 'assets/pets/moomew/review.webp',
      frameDurations: [150, 150, 150, 150, 150, 280],
    ),
    'drag-left': _PetClip(
      key: 'moomew-drag-left',
      asset: 'assets/pets/moomew/running-left.webp',
      frameDurations: [120, 120, 120, 120, 120, 120, 120, 220],
    ),
  };

  static const _xiaohei = <String, _PetClip>{
    'idle': _PetClip(
      key: 'xiaohei-idle',
      asset: 'assets/pets/xiaohei/idle.webp',
      frameDurations: [70, 70, 70, 70, 70, 70, 70, 70, 70, 70],
    ),
    'guitar': _PetClip(
      key: 'xiaohei-guitar',
      asset: 'assets/pets/xiaohei/guitar.webp',
      frameDurations: [80, 80, 80, 80, 80, 80],
    ),
    'groom': _PetClip(
      key: 'xiaohei-groom',
      asset: 'assets/pets/xiaohei/groom.webp',
      frameDurations: [80, 80, 80, 80, 80, 80, 80, 80],
    ),
    'bye': _PetClip(
      key: 'xiaohei-bye',
      asset: 'assets/pets/xiaohei/bye.webp',
      frameDurations: [
        80,
        80,
        80,
        80,
        80,
        80,
        80,
        80,
        80,
        80,
        80,
        80,
        80,
        80,
        80,
        80,
      ],
    ),
    'play': _PetClip(
      key: 'xiaohei-play',
      asset: 'assets/pets/xiaohei/play.webp',
      frameDurations: [70, 70, 70, 70, 70],
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
    ),
  };

  static const _whale = <String, _PetClip>{
    'idle': _PetClip(
      key: 'whale-idle',
      asset: 'assets/pets/whale_girl/idle.webp',
      frameDurations: [1500, 160, 320],
    ),
    'working': _PetClip(
      key: 'whale-working',
      asset: 'assets/pets/whale_girl/working.webp',
      frameDurations: [340, 340, 340],
    ),
    'celebrate': _PetClip(
      key: 'whale-celebrate',
      asset: 'assets/pets/whale_girl/celebrate.webp',
      frameDurations: [250, 250, 250],
    ),
    'error': _PetClip(
      key: 'whale-error',
      asset: 'assets/pets/whale_girl/error.webp',
      frameDurations: [125, 600],
    ),
    'disappointed': _PetClip(
      key: 'whale-disappointed',
      asset: 'assets/pets/whale_girl/disappointed.webp',
      frameDurations: [500, 500],
    ),
    'joy': _PetClip(
      key: 'whale-joy',
      asset: 'assets/pets/whale_girl/joy.webp',
      frameDurations: [200, 200],
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
    ),
    'wake': _PetClip(
      key: 'whale-wake',
      asset: 'assets/pets/whale_girl/wake.webp',
      frameDurations: [1000, 200],
    ),
    'welcome': _PetClip(
      key: 'whale-welcome',
      asset: 'assets/pets/whale_girl/welcome.webp',
      frameDurations: [330, 330],
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
  }) {
    return switch (appearance) {
      AiPetAppearance.moomew => _moomewClip(mode, interaction, dragging),
      AiPetAppearance.xiaohei => _xiaoheiClip(mode, interaction, dragging),
      AiPetAppearance.whaleGirl => _whaleClip(mode, interaction, dragging),
      AiPetAppearance.kuzai => throw StateError(
        'Kuzai uses its vector painter',
      ),
    };
  }

  static Iterable<String> warmupAssets({
    required AiPetAppearance appearance,
    required AssistantPetMode mode,
    required AssistantPetInteraction interaction,
    required bool dragging,
    required String currentAsset,
  }) {
    if (appearance == AiPetAppearance.kuzai) return const [];
    if (dragging || interaction != AssistantPetInteraction.none) {
      final baseClip = resolve(
        appearance: appearance,
        mode: mode,
        interaction: AssistantPetInteraction.none,
        dragging: false,
      );
      return baseClip.asset == currentAsset ? const [] : [baseClip.asset];
    }

    final clips = switch (appearance) {
      AiPetAppearance.moomew => _clipsForKeys(_moomew, switch (mode) {
        AssistantPetMode.idle => const ['wave', 'jump', 'drag-left', 'wait'],
        AssistantPetMode.waking => const ['wait'],
        AssistantPetMode.listening ||
        AssistantPetMode.textOnly ||
        AssistantPetMode.paused => const ['review'],
        AssistantPetMode.thinking => const ['wave', 'wait'],
        AssistantPetMode.speaking => const ['wait'],
        AssistantPetMode.stopping || AssistantPetMode.error => const ['idle'],
      }),
      AiPetAppearance.xiaohei => _clipsForKeys(_xiaohei, switch (mode) {
        AssistantPetMode.idle => const ['play', 'groom'],
        AssistantPetMode.waking => const ['idle'],
        AssistantPetMode.listening ||
        AssistantPetMode.textOnly ||
        AssistantPetMode.paused => const ['groom'],
        AssistantPetMode.thinking => const ['guitar'],
        AssistantPetMode.speaking => const ['idle', 'bye'],
        AssistantPetMode.stopping || AssistantPetMode.error => const ['idle'],
      }),
      AiPetAppearance.whaleGirl => _clipsForKeys(_whale, switch (mode) {
        AssistantPetMode.idle => const ['welcome', 'joy', 'drag', 'wake'],
        AssistantPetMode.waking => const ['wait'],
        AssistantPetMode.listening ||
        AssistantPetMode.textOnly ||
        AssistantPetMode.paused => const ['think'],
        AssistantPetMode.thinking => const ['working'],
        AssistantPetMode.speaking => const ['wait', 'welcome'],
        AssistantPetMode.stopping || AssistantPetMode.error => const ['idle'],
      }),
      AiPetAppearance.kuzai => const <_PetClip>[],
    };
    return clips
        .map((clip) => clip.asset)
        .where((asset) => asset != currentAsset);
  }

  static List<_PetClip> _clipsForKeys(
    Map<String, _PetClip> clips,
    List<String> keys,
  ) => keys.map((key) => clips[key]!).toList(growable: false);

  static _PetClip _moomewClip(
    AssistantPetMode mode,
    AssistantPetInteraction interaction,
    bool dragging,
  ) {
    if (dragging) return _moomew['drag-left']!;
    if (interaction == AssistantPetInteraction.petting) return _moomew['jump']!;
    if (interaction == AssistantPetInteraction.wave) return _moomew['wave']!;
    return switch (mode) {
      AssistantPetMode.waking => _moomew['jump']!,
      AssistantPetMode.listening ||
      AssistantPetMode.textOnly ||
      AssistantPetMode.paused => _moomew['wait']!,
      AssistantPetMode.thinking => _moomew['review']!,
      AssistantPetMode.speaking => _moomew['wave']!,
      AssistantPetMode.stopping => _moomew['wave']!,
      AssistantPetMode.error => _moomew['error']!,
      AssistantPetMode.idle => _moomew['idle']!,
    };
  }

  static _PetClip _xiaoheiClip(
    AssistantPetMode mode,
    AssistantPetInteraction interaction,
    bool dragging,
  ) {
    if (dragging) return _xiaohei['play']!;
    if (interaction == AssistantPetInteraction.petting) {
      return _xiaohei['groom']!;
    }
    if (interaction == AssistantPetInteraction.wave) return _xiaohei['play']!;
    return switch (mode) {
      AssistantPetMode.waking => _xiaohei['play']!,
      AssistantPetMode.thinking => _xiaohei['groom']!,
      AssistantPetMode.speaking => _xiaohei['guitar']!,
      AssistantPetMode.stopping => _xiaohei['bye']!,
      AssistantPetMode.error => _xiaohei['bye']!,
      AssistantPetMode.listening ||
      AssistantPetMode.textOnly ||
      AssistantPetMode.paused ||
      AssistantPetMode.idle => _xiaohei['idle']!,
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
      AssistantPetMode.textOnly ||
      AssistantPetMode.paused => _whale['wait']!,
      AssistantPetMode.thinking => _whale['think']!,
      AssistantPetMode.speaking => _whale['working']!,
      AssistantPetMode.stopping => _whale['welcome']!,
      AssistantPetMode.error => _whale['error']!,
      AssistantPetMode.idle => _whale['idle']!,
    };
  }
}
