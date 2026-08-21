import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum KuzaiPetMode {
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

enum _KuzaiIdleAction {
  none,
  blink,
  earTwitch,
  tailSway,
  headTilt,
  postureShift,
  groom,
  stretch,
  yawn,
}

enum _KuzaiInteraction { none, wave, petting }

class KuzaiPet extends StatefulWidget {
  final double size;
  final KuzaiPetMode mode;
  final VoidCallback onTap;

  const KuzaiPet({
    super.key,
    required this.size,
    required this.mode,
    required this.onTap,
  });

  @override
  State<KuzaiPet> createState() => _KuzaiPetState();
}

class _KuzaiPetState extends State<KuzaiPet> with TickerProviderStateMixin {
  static bool _entryPlayed = false;

  final math.Random _random = math.Random();
  late final AnimationController _idleController;
  late final AnimationController _interactionController;
  late final AnimationController _headphonesController;
  late final AnimationController _stateController;
  late final AnimationController _entryController;
  late final Listenable _animation;
  Timer? _idleTimer;
  Timer? _stateTimer;
  _KuzaiIdleAction _idleAction = _KuzaiIdleAction.none;
  _KuzaiInteraction _interaction = _KuzaiInteraction.none;
  DateTime _nextLargeAction = DateTime.now();
  double _petLeanDirection = -1;

  @override
  void initState() {
    super.initState();
    _idleController = AnimationController(vsync: this)
      ..addStatusListener(_handleIdleStatus);
    _interactionController = AnimationController(vsync: this)
      ..addStatusListener(_handleInteractionStatus);
    _headphonesController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
      value: _modeUsesHeadphones(widget.mode) ? 1 : 0,
    );
    _stateController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 720),
    );
    final playEntry = !_entryPlayed;
    _entryPlayed = true;
    _entryController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
      value: playEntry ? 0 : 1,
    );
    if (playEntry) _entryController.forward();
    _animation = Listenable.merge([
      _idleController,
      _interactionController,
      _headphonesController,
      _stateController,
      _entryController,
    ]);
    _nextLargeAction = _futureLargeAction();
    _scheduleIdle(initial: true);
    _startStatePulse();
  }

  @override
  void didUpdateWidget(covariant KuzaiPet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mode == widget.mode) return;
    if (_modeUsesHeadphones(widget.mode)) {
      _headphonesController.forward();
    } else {
      _headphonesController.reverse();
    }
    _idleTimer?.cancel();
    _idleController.stop();
    if (_idleAction != _KuzaiIdleAction.none) {
      _idleAction = _KuzaiIdleAction.none;
    }
    if (widget.mode == KuzaiPetMode.idle) {
      _scheduleIdle();
    }
    _startStatePulse();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _stateTimer?.cancel();
    _idleController.dispose();
    _interactionController.dispose();
    _headphonesController.dispose();
    _stateController.dispose();
    _entryController.dispose();
    super.dispose();
  }

  bool _modeUsesHeadphones(KuzaiPetMode mode) =>
      mode != KuzaiPetMode.idle && mode != KuzaiPetMode.stopping;

  DateTime _futureLargeAction() =>
      DateTime.now().add(Duration(seconds: 50 + _random.nextInt(31)));

  void _scheduleIdle({bool initial = false}) {
    _idleTimer?.cancel();
    if (widget.mode != KuzaiPetMode.idle) return;
    final seconds = initial ? 8 : 7 + _random.nextInt(6);
    _idleTimer = Timer(Duration(seconds: seconds), _runIdleAction);
  }

  void _runIdleAction() {
    if (!mounted || widget.mode != KuzaiPetMode.idle) return;
    final now = DateTime.now();
    final action = now.isAfter(_nextLargeAction)
        ? _largeAction()
        : _smallAction();
    if (now.isAfter(_nextLargeAction)) {
      _nextLargeAction = _futureLargeAction();
    }
    setState(() => _idleAction = action);
    _idleController.duration = switch (action) {
      _KuzaiIdleAction.blink => const Duration(milliseconds: 260),
      _KuzaiIdleAction.earTwitch => const Duration(milliseconds: 560),
      _KuzaiIdleAction.tailSway => const Duration(milliseconds: 1200),
      _KuzaiIdleAction.headTilt => const Duration(milliseconds: 1300),
      _KuzaiIdleAction.postureShift => const Duration(milliseconds: 1450),
      _KuzaiIdleAction.groom => const Duration(milliseconds: 2500),
      _KuzaiIdleAction.stretch => const Duration(milliseconds: 2300),
      _KuzaiIdleAction.yawn => const Duration(milliseconds: 2200),
      _ => const Duration(milliseconds: 800),
    };
    _idleController.forward(from: 0);
  }

  _KuzaiIdleAction _smallAction() {
    const actions = [
      _KuzaiIdleAction.blink,
      _KuzaiIdleAction.blink,
      _KuzaiIdleAction.earTwitch,
      _KuzaiIdleAction.tailSway,
      _KuzaiIdleAction.headTilt,
      _KuzaiIdleAction.postureShift,
    ];
    return actions[_random.nextInt(actions.length)];
  }

  _KuzaiIdleAction _largeAction() {
    const actions = [
      _KuzaiIdleAction.groom,
      _KuzaiIdleAction.stretch,
      _KuzaiIdleAction.yawn,
    ];
    return actions[_random.nextInt(actions.length)];
  }

  void _handleIdleStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    setState(() => _idleAction = _KuzaiIdleAction.none);
    _scheduleIdle();
  }

  void _startStatePulse() {
    _stateTimer?.cancel();
    _stateController.stop();
    final interval = switch (widget.mode) {
      KuzaiPetMode.listening => const Duration(milliseconds: 1550),
      KuzaiPetMode.thinking => const Duration(milliseconds: 1800),
      KuzaiPetMode.speaking => const Duration(milliseconds: 720),
      _ => null,
    };
    if (interval == null) {
      _stateController.value = 0;
      return;
    }
    _stateController.duration = interval * 0.55;
    _stateController.forward(from: 0);
    _stateTimer = Timer.periodic(interval, (_) {
      if (mounted && !_stateController.isAnimating) {
        _stateController.forward(from: 0);
      }
    });
  }

  void _handleTap() {
    setState(() => _interaction = _KuzaiInteraction.wave);
    _interactionController.duration = const Duration(milliseconds: 950);
    _interactionController.forward(from: 0);
    widget.onTap();
  }

  void _handleLongPress(LongPressStartDetails details) {
    _petLeanDirection = details.localPosition.dx < widget.size * 0.56 ? -1 : 1;
    setState(() => _interaction = _KuzaiInteraction.petting);
    _interactionController.duration = const Duration(milliseconds: 1600);
    _interactionController.forward(from: 0);
    unawaited(HapticFeedback.lightImpact());
  }

  void _handleInteractionStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    setState(() => _interaction = _KuzaiInteraction.none);
  }

  String get _semanticValue {
    if (_interaction == _KuzaiInteraction.wave) return '正在挥爪打招呼';
    if (_interaction == _KuzaiInteraction.petting) return '正在享受摸摸';
    return switch (widget.mode) {
      KuzaiPetMode.idle => '空闲',
      KuzaiPetMode.waking => '正在戴耳机',
      KuzaiPetMode.listening => '正在聆听',
      KuzaiPetMode.thinking => '正在思考',
      KuzaiPetMode.speaking => '正在回答',
      KuzaiPetMode.textOnly => '等待文字输入',
      KuzaiPetMode.paused => '已暂停聆听',
      KuzaiPetMode.stopping => '正在告别',
      KuzaiPetMode.error => '遇到问题',
    };
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '打开库仔 AI 助手',
      hint: '点击对话，拖动可移动位置，长按摸摸库仔',
      value: _semanticValue,
      onTap: _handleTap,
      onLongPress: () => _handleLongPress(
        LongPressStartDetails(localPosition: Offset(widget.size * 0.56, 0)),
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _handleTap,
        onLongPressStart: _handleLongPress,
        child: RepaintBoundary(
          child: SizedBox(
            width: widget.size * 1.12,
            height: widget.size,
            child: AnimatedBuilder(
              animation: _animation,
              builder: (context, _) => Stack(
                fit: StackFit.expand,
                children: [
                  ExcludeSemantics(
                    child: CustomPaint(
                      key: const ValueKey('kuzai-pet-canvas'),
                      painter: _KuzaiPetPainter(
                        mode: widget.mode,
                        idleAction: _idleAction,
                        idleProgress: _idleController.value,
                        interaction: _interaction,
                        interactionProgress: _interactionController.value,
                        headphonesProgress: _headphonesController.value,
                        stateProgress: _stateController.value,
                        entryProgress: _entryController.value,
                        petLeanDirection: _petLeanDirection,
                      ),
                    ),
                  ),
                  SizedBox.expand(
                    key: ValueKey('kuzai-pet-mode-${widget.mode.name}'),
                  ),
                  if (_interaction == _KuzaiInteraction.wave)
                    const SizedBox.expand(
                      key: ValueKey('kuzai-pet-wave-active'),
                    ),
                  if (_interaction == _KuzaiInteraction.petting)
                    const SizedBox.expand(
                      key: ValueKey('kuzai-pet-petting-active'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _KuzaiPetPainter extends CustomPainter {
  static const _gray = Color(0xFFACA3AA);
  static const _grayLight = Color(0xFFD8D1D2);
  static const _grayDark = Color(0xFF746B78);
  static const _white = Color(0xFFFFFAF8);
  static const _pink = Color(0xFFF6A5B9);
  static const _purple = Color(0xFF7957D8);
  static const _purpleLight = Color(0xFFC8B7FF);
  static const _purpleDark = Color(0xFF4D359F);
  static const _ink = Color(0xFF3D3148);

  final KuzaiPetMode mode;
  final _KuzaiIdleAction idleAction;
  final double idleProgress;
  final _KuzaiInteraction interaction;
  final double interactionProgress;
  final double headphonesProgress;
  final double stateProgress;
  final double entryProgress;
  final double petLeanDirection;

  const _KuzaiPetPainter({
    required this.mode,
    required this.idleAction,
    required this.idleProgress,
    required this.interaction,
    required this.interactionProgress,
    required this.headphonesProgress,
    required this.stateProgress,
    required this.entryProgress,
    required this.petLeanDirection,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(size.width / 112, size.height / 100);
    canvas.save();
    canvas.translate((size.width - 112 * scale) / 2, size.height - 100 * scale);
    canvas.scale(scale);
    final entryValue = Curves.easeOutBack.transform(entryProgress);
    final entryScale = 0.82 + entryValue * 0.18;
    canvas.translate((1 - entryValue) * 18, (1 - entryValue) * 16);
    canvas.translate(56, 100);
    canvas.scale(entryScale, entryScale);
    canvas.translate(-56, -100);

    final idleWave = math.sin(math.pi * idleProgress);
    final interactionWave = math.sin(math.pi * interactionProgress);
    final stateWave = math.sin(math.pi * stateProgress);
    var headAngle = 0.0;
    var headShiftX = 0.0;
    var headShiftY = 0.0;
    var bodyShiftX = 0.0;
    var bodyShiftY = 0.0;
    var bodyScaleY = 1.0;
    var eyeOpen = 1.0;
    var mouthOpen = 0.0;
    var leftEarAngle = 0.0;
    var rightEarAngle = 0.0;
    var tailAngle = 0.0;
    var leftPawAngle = 0.0;
    var rightPawAngle = 0.0;
    var pupilX = 0.0;
    var pupilY = 0.0;
    var headphoneGlow = 0.0;

    switch (idleAction) {
      case _KuzaiIdleAction.blink:
        eyeOpen = 1 - idleWave;
        break;
      case _KuzaiIdleAction.earTwitch:
        leftEarAngle = math.sin(idleProgress * math.pi * 4) * 0.12;
        break;
      case _KuzaiIdleAction.tailSway:
        tailAngle = math.sin(idleProgress * math.pi * 2) * 0.22;
        break;
      case _KuzaiIdleAction.headTilt:
        headAngle = idleWave * 0.13;
        break;
      case _KuzaiIdleAction.postureShift:
        bodyShiftX = idleWave * 2.4;
        headShiftX = idleWave * 1.4;
        tailAngle = -idleWave * 0.12;
        break;
      case _KuzaiIdleAction.groom:
        eyeOpen = 1 - idleWave * 0.9;
        headAngle = -idleWave * 0.09;
        leftPawAngle = -idleWave * 2.68;
        mouthOpen = idleWave * 0.28;
        break;
      case _KuzaiIdleAction.stretch:
        headShiftX = -idleWave * 7;
        headShiftY = idleWave * 5;
        bodyShiftY = idleWave * 2.5;
        bodyScaleY = 1 - idleWave * 0.12;
        leftPawAngle = idleWave * 1.05;
        rightPawAngle = -idleWave * 1.05;
        tailAngle = -idleWave * 0.16;
        break;
      case _KuzaiIdleAction.yawn:
        eyeOpen = 1 - idleWave;
        mouthOpen = idleWave;
        headAngle = -idleWave * 0.08;
        leftEarAngle = idleWave * 0.1;
        rightEarAngle = -idleWave * 0.1;
        break;
      case _KuzaiIdleAction.none:
        break;
    }

    switch (mode) {
      case KuzaiPetMode.waking:
        eyeOpen = 1;
        break;
      case KuzaiPetMode.listening:
        headShiftY -= 1.2;
        bodyShiftY -= 0.8;
        headphoneGlow = stateWave;
        break;
      case KuzaiPetMode.thinking:
        headAngle -= 0.11;
        pupilX = -1.5;
        pupilY = -1.5;
        rightPawAngle = 2.58;
        tailAngle += stateWave * 0.05;
        break;
      case KuzaiPetMode.speaking:
        mouthOpen = stateWave * 0.65;
        leftPawAngle = stateWave * 1.85;
        headAngle += stateWave * 0.025;
        headphoneGlow = stateWave * 0.45;
        break;
      case KuzaiPetMode.textOnly:
        headAngle += 0.1;
        rightEarAngle -= 0.1;
        break;
      case KuzaiPetMode.paused:
        eyeOpen = 0.82;
        break;
      case KuzaiPetMode.stopping:
        headAngle -= interactionWave * 0.04;
        break;
      case KuzaiPetMode.error:
        eyeOpen = 0.76;
        leftEarAngle += 0.16;
        rightEarAngle -= 0.16;
        leftPawAngle = -0.2;
        rightPawAngle = 0.2;
        break;
      case KuzaiPetMode.idle:
        break;
    }

    final headphonesMotion = math.sin(math.pi * headphonesProgress);
    leftPawAngle = _strongerAngle(leftPawAngle, headphonesMotion * 2.62);
    rightPawAngle = _strongerAngle(rightPawAngle, headphonesMotion * -2.62);

    if (interaction == _KuzaiInteraction.none && entryProgress > 0.58) {
      final waveProgress = ((entryProgress - 0.58) / 0.42)
          .clamp(0.0, 1.0)
          .toDouble();
      final entryWave = math.sin(math.pi * waveProgress);
      leftPawAngle =
          entryWave * 2.38 +
          math.sin(waveProgress * math.pi * 4) * entryWave * 0.14;
      headAngle -= entryWave * 0.04;
    }

    if (interaction == _KuzaiInteraction.wave) {
      leftPawAngle =
          interactionWave * 2.38 +
          math.sin(interactionProgress * math.pi * 4) * interactionWave * 0.16;
      headAngle -= interactionWave * 0.05;
      eyeOpen = 1;
    } else if (interaction == _KuzaiInteraction.petting) {
      eyeOpen = 0;
      headAngle += petLeanDirection * interactionWave * 0.12;
      headShiftX += petLeanDirection * interactionWave * 2;
      tailAngle += math.sin(interactionProgress * math.pi * 2) * 0.12;
    }

    _drawGround(canvas);
    _drawTail(canvas, tailAngle, bodyShiftX, bodyShiftY);
    _drawBody(
      canvas,
      shiftX: bodyShiftX,
      shiftY: bodyShiftY,
      scaleY: bodyScaleY,
    );
    final headCenter = Offset(
      50 + bodyShiftX + headShiftX,
      35 + bodyShiftY * 0.35 + headShiftY,
    );
    _drawHead(
      canvas,
      center: headCenter,
      angle: headAngle,
      eyeOpen: eyeOpen.clamp(0.0, 1.0).toDouble(),
      mouthOpen: mouthOpen.clamp(0.0, 1.0).toDouble(),
      pupilOffset: Offset(pupilX, pupilY),
      leftEarAngle: leftEarAngle,
      rightEarAngle: rightEarAngle,
      headphoneProgress: headphonesProgress,
      headphoneGlow: headphoneGlow,
    );
    _drawForePaw(
      canvas,
      shoulder: Offset(39 + bodyShiftX, 62 + bodyShiftY),
      angle: leftPawAngle,
      mirror: false,
    );
    _drawForePaw(
      canvas,
      shoulder: Offset(61 + bodyShiftX, 62 + bodyShiftY),
      angle: rightPawAngle,
      mirror: true,
    );
    if (interaction == _KuzaiInteraction.petting) {
      _drawHearts(canvas, interactionProgress, petLeanDirection);
    }
    canvas.restore();
  }

  double _strongerAngle(double current, double candidate) =>
      candidate.abs() > current.abs() ? candidate : current;

  void _drawGround(Canvas canvas) {
    final paint = Paint()
      ..color = const Color(0x332F2250)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    canvas.drawOval(const Rect.fromLTWH(19, 88, 67, 7), paint);
  }

  void _drawTail(Canvas canvas, double angle, double shiftX, double shiftY) {
    canvas.save();
    canvas.translate(73 + shiftX, 77 + shiftY);
    canvas.rotate(angle);
    final path = Path()
      ..moveTo(0, 0)
      ..cubicTo(18, 0, 21, -22, 10, -30);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 11.5
      ..strokeCap = StrokeCap.round
      ..shader = const LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [_gray, _grayLight, Color(0xFFF6EDE8)],
        stops: [0, 0.72, 1],
      ).createShader(const Rect.fromLTWH(0, -34, 27, 36));
    canvas.drawPath(path, paint);
    canvas.restore();
  }

  void _drawBody(
    Canvas canvas, {
    required double shiftX,
    required double shiftY,
    required double scaleY,
  }) {
    canvas.save();
    canvas.translate(50 + shiftX, 69 + shiftY);
    canvas.scale(1, scaleY);
    canvas.translate(-50, -69);
    const bodyRect = Rect.fromLTWH(26, 44, 48, 48);
    final bodyPaint = Paint()
      ..shader = const RadialGradient(
        center: Alignment(-0.28, -0.35),
        radius: 0.85,
        colors: [_grayLight, _gray, _grayDark],
        stops: [0, 0.72, 1],
      ).createShader(bodyRect);
    canvas.drawShadow(
      Path()..addOval(bodyRect),
      const Color(0x553D3150),
      3,
      true,
    );
    canvas.drawOval(bodyRect, bodyPaint);
    canvas.drawOval(
      const Rect.fromLTWH(38, 51, 24, 36),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_white, Color(0xFFF0E9E8)],
        ).createShader(const Rect.fromLTWH(38, 51, 24, 36)),
    );
    _drawHindPaw(canvas, const Offset(28, 84), false);
    _drawHindPaw(canvas, const Offset(72, 84), true);
    canvas.restore();
  }

  void _drawHindPaw(Canvas canvas, Offset center, bool mirror) {
    final rect = Rect.fromCenter(center: center, width: 22, height: 16);
    canvas.drawOval(
      rect,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(0, -0.35),
          colors: [_white, Color(0xFFE6DDDE)],
        ).createShader(rect),
    );
    final direction = mirror ? -1.0 : 1.0;
    canvas.drawOval(
      Rect.fromCenter(
        center: center.translate(direction * 0.6, 2.4),
        width: 7.5,
        height: 6,
      ),
      Paint()..color = _pink.withValues(alpha: 0.88),
    );
    for (var index = 0; index < 3; index++) {
      final dx = (index - 1) * 4.2;
      canvas.drawCircle(
        center.translate(dx, -3.2),
        1.65,
        Paint()..color = _pink.withValues(alpha: 0.82),
      );
    }
  }

  void _drawHead(
    Canvas canvas, {
    required Offset center,
    required double angle,
    required double eyeOpen,
    required double mouthOpen,
    required Offset pupilOffset,
    required double leftEarAngle,
    required double rightEarAngle,
    required double headphoneProgress,
    required double headphoneGlow,
  }) {
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(angle);
    _drawHeadphoneBand(canvas, headphoneProgress);
    _drawEar(canvas, const Offset(-18, -16), false, leftEarAngle);
    _drawEar(canvas, const Offset(18, -16), true, rightEarAngle);
    const headRect = Rect.fromLTWH(-30, -24, 60, 51);
    canvas.drawShadow(
      Path()..addOval(headRect),
      const Color(0x553D3150),
      3.5,
      true,
    );
    canvas.drawOval(
      headRect,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.32, -0.42),
          radius: 0.92,
          colors: [_grayLight, _gray, _grayDark],
          stops: [0, 0.76, 1],
        ).createShader(headRect),
    );
    _drawFaceBlaze(canvas);
    _drawEyes(canvas, eyeOpen, pupilOffset);
    _drawMuzzle(canvas, mouthOpen);
    _drawCollar(canvas);
    _drawHeadphoneCups(canvas, headphoneProgress, headphoneGlow);
    canvas.restore();
  }

  void _drawEar(Canvas canvas, Offset base, bool mirror, double angle) {
    canvas.save();
    canvas.translate(base.dx, base.dy);
    canvas.rotate(angle);
    final direction = mirror ? -1.0 : 1.0;
    final path = Path()
      ..moveTo(-10 * direction, 7)
      ..quadraticBezierTo(-7 * direction, -13, 0, -18)
      ..quadraticBezierTo(9 * direction, -8, 12 * direction, 9)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_grayDark, _gray],
        ).createShader(const Rect.fromLTWH(-12, -19, 24, 29)),
    );
    final inner = Path()
      ..moveTo(-5 * direction, 4)
      ..quadraticBezierTo(-4 * direction, -8, 0, -12)
      ..quadraticBezierTo(6 * direction, -5, 7 * direction, 5)
      ..close();
    canvas.drawPath(inner, Paint()..color = _pink.withValues(alpha: 0.86));
    canvas.restore();
  }

  void _drawFaceBlaze(Canvas canvas) {
    final blaze = Path()
      ..moveTo(-8, -23)
      ..quadraticBezierTo(-6, -12, -10, -3)
      ..quadraticBezierTo(-14, 9, 0, 19)
      ..quadraticBezierTo(14, 9, 10, -3)
      ..quadraticBezierTo(6, -12, 8, -23)
      ..quadraticBezierTo(2, -17, 0, -11)
      ..quadraticBezierTo(-2, -17, -8, -23)
      ..close();
    canvas.drawPath(
      blaze,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFF4EEEE), _white],
        ).createShader(const Rect.fromLTWH(-14, -24, 28, 44)),
    );
    final marking = Paint()
      ..color = _grayDark.withValues(alpha: 0.42)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      const Rect.fromLTWH(-15, -17, 12, 8),
      0.2,
      1.05,
      false,
      marking,
    );
    canvas.drawArc(
      const Rect.fromLTWH(3, -17, 12, 8),
      1.88,
      1.05,
      false,
      marking,
    );
    canvas.drawLine(const Offset(0, -16), const Offset(0, -10), marking);
  }

  void _drawEyes(Canvas canvas, double eyeOpen, Offset pupilOffset) {
    _drawEye(canvas, const Offset(-11, 1), eyeOpen, pupilOffset);
    _drawEye(canvas, const Offset(11, 1), eyeOpen, pupilOffset);
  }

  void _drawEye(
    Canvas canvas,
    Offset center,
    double eyeOpen,
    Offset pupilOffset,
  ) {
    if (eyeOpen < 0.12) {
      final path = Path()
        ..moveTo(center.dx - 5, center.dy)
        ..quadraticBezierTo(
          center.dx,
          center.dy + 3.4,
          center.dx + 5,
          center.dy,
        );
      canvas.drawPath(
        path,
        Paint()
          ..color = _ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..strokeCap = StrokeCap.round,
      );
      return;
    }
    final height = 13 * eyeOpen.clamp(0.2, 1.0).toDouble();
    final eyeRect = Rect.fromCenter(center: center, width: 10, height: height);
    canvas.drawOval(eyeRect, Paint()..color = const Color(0xFFFFFDFD));
    final irisCenter = center + pupilOffset;
    final irisRect = Rect.fromCenter(
      center: irisCenter,
      width: 7.8,
      height: math.max(4.2, height - 1.8).toDouble(),
    );
    canvas.drawOval(
      irisRect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_purpleDark, Color(0xFF5E55D8), Color(0xFF7FB9FF)],
        ).createShader(irisRect),
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: irisCenter.translate(0, 0.7),
        width: 3.4,
        height: math.max(2.8, height * 0.58).toDouble(),
      ),
      Paint()..color = const Color(0xFF241B4D),
    );
    canvas.drawCircle(
      irisCenter.translate(-1.8, -2.2),
      1.55,
      Paint()..color = Colors.white,
    );
    canvas.drawCircle(
      irisCenter.translate(1.5, 1.8),
      0.7,
      Paint()..color = Colors.white.withValues(alpha: 0.82),
    );
  }

  void _drawMuzzle(Canvas canvas, double mouthOpen) {
    canvas.drawOval(
      const Rect.fromLTWH(-12, 8, 13, 11),
      Paint()..color = _white.withValues(alpha: 0.96),
    );
    canvas.drawOval(
      const Rect.fromLTWH(-1, 8, 13, 11),
      Paint()..color = _white.withValues(alpha: 0.96),
    );
    canvas.drawOval(
      const Rect.fromLTWH(-25, 7, 10, 7),
      Paint()..color = _pink.withValues(alpha: 0.2),
    );
    canvas.drawOval(
      const Rect.fromLTWH(15, 7, 10, 7),
      Paint()..color = _pink.withValues(alpha: 0.2),
    );
    final nose = Path()
      ..moveTo(-3.2, 8.3)
      ..quadraticBezierTo(0, 6.1, 3.2, 8.3)
      ..quadraticBezierTo(0, 12, -3.2, 8.3)
      ..close();
    canvas.drawPath(nose, Paint()..color = _pink);
    if (mouthOpen > 0.12) {
      final mouthRect = Rect.fromCenter(
        center: const Offset(0, 15),
        width: 7 + mouthOpen * 3,
        height: 2 + mouthOpen * 8,
      );
      canvas.drawOval(mouthRect, Paint()..color = _ink);
      canvas.drawOval(
        Rect.fromCenter(
          center: mouthRect.center.translate(0, mouthRect.height * 0.24),
          width: mouthRect.width * 0.62,
          height: mouthRect.height * 0.28,
        ),
        Paint()..color = _pink,
      );
    } else {
      final mouth = Path()
        ..moveTo(0, 11)
        ..quadraticBezierTo(-2.2, 15.2, -5.5, 13.5)
        ..moveTo(0, 11)
        ..quadraticBezierTo(2.2, 15.2, 5.5, 13.5);
      canvas.drawPath(
        mouth,
        Paint()
          ..color = _ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3
          ..strokeCap = StrokeCap.round,
      );
    }
    final whiskerPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.82)
      ..strokeWidth = 0.75
      ..strokeCap = StrokeCap.round;
    for (final y in [8.0, 12.0]) {
      canvas.drawLine(Offset(-16, y), Offset(-30, y - 2), whiskerPaint);
      canvas.drawLine(Offset(16, y), Offset(30, y - 2), whiskerPaint);
    }
  }

  void _drawCollar(Canvas canvas) {
    canvas.drawArc(
      const Rect.fromLTWH(-18, 18, 36, 13),
      0.12,
      math.pi - 0.24,
      false,
      Paint()
        ..color = _purple
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.4
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(
      const Offset(0, 28),
      5.3,
      Paint()
        ..shader = const RadialGradient(
          colors: [Colors.white, _purpleLight],
        ).createShader(const Rect.fromLTWH(-6, 22, 12, 12)),
    );
    canvas.drawCircle(
      const Offset(0, 28),
      5.3,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..color = _purple,
    );
    final note = Path()
      ..addOval(const Rect.fromLTWH(-2.3, 28, 2.8, 2.2))
      ..moveTo(0, 28.7)
      ..lineTo(0.7, 24.3)
      ..lineTo(3.2, 25.2);
    canvas.drawPath(
      note,
      Paint()
        ..color = _purple
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..strokeCap = StrokeCap.round,
    );
  }

  void _drawHeadphoneBand(Canvas canvas, double progress) {
    final y = 18 - progress * 30;
    final width = 42 + progress * 8;
    final rect = Rect.fromCenter(
      center: Offset(0, y + 4),
      width: width,
      height: 28 + progress * 8,
    );
    canvas.drawArc(
      rect,
      math.pi * 1.08,
      math.pi * 0.84,
      false,
      Paint()
        ..color = _purpleLight
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawArc(
      rect,
      math.pi * 1.08,
      math.pi * 0.84,
      false,
      Paint()
        ..color = _purple
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.3
        ..strokeCap = StrokeCap.round,
    );
  }

  void _drawHeadphoneCups(Canvas canvas, double progress, double glow) {
    final y = 22 - progress * 24;
    final x = 20 + progress * 9;
    _drawHeadphoneCup(canvas, Offset(-x, y), glow);
    _drawHeadphoneCup(canvas, Offset(x, y), glow);
  }

  void _drawHeadphoneCup(Canvas canvas, Offset center, double glow) {
    if (glow > 0) {
      canvas.drawCircle(
        center,
        10 + glow * 2.2,
        Paint()
          ..color = _purpleLight.withValues(alpha: glow * 0.28)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
    }
    canvas.drawCircle(center, 8.6, Paint()..color = const Color(0xFFF6F1FF));
    canvas.drawCircle(
      center,
      7.1,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.35, -0.45),
          colors: [_purpleLight, _purple, _purpleDark],
        ).createShader(Rect.fromCircle(center: center, radius: 7.1)),
    );
    final pawPaint = Paint()..color = Colors.white;
    canvas.drawOval(
      Rect.fromCenter(
        center: center.translate(0, 1.7),
        width: 4.2,
        height: 3.6,
      ),
      pawPaint,
    );
    for (final offset in const [
      Offset(-2.4, -1.7),
      Offset(-0.8, -2.7),
      Offset(1.1, -2.6),
      Offset(2.5, -1.4),
    ]) {
      canvas.drawCircle(center + offset, 0.9, pawPaint);
    }
  }

  void _drawForePaw(
    Canvas canvas, {
    required Offset shoulder,
    required double angle,
    required bool mirror,
  }) {
    canvas.save();
    canvas.translate(shoulder.dx, shoulder.dy);
    canvas.rotate(angle);
    const limbRect = Rect.fromLTWH(-5.2, -1, 10.4, 26);
    canvas.drawRRect(
      RRect.fromRectAndRadius(limbRect, const Radius.circular(5.2)),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_grayLight, _white],
          stops: [0, 0.68],
        ).createShader(limbRect),
    );
    const pawCenter = Offset(0, 24);
    canvas.drawOval(
      Rect.fromCenter(center: pawCenter, width: 11.5, height: 9),
      Paint()..color = _white,
    );
    if (angle.abs() > 1.4) {
      canvas.drawOval(
        Rect.fromCenter(
          center: pawCenter.translate(mirror ? -0.3 : 0.3, 0.7),
          width: 4.3,
          height: 3.5,
        ),
        Paint()..color = _pink.withValues(alpha: 0.86),
      );
    }
    canvas.restore();
  }

  void _drawHearts(Canvas canvas, double progress, double direction) {
    for (var index = 0; index < 3; index++) {
      final phase = ((progress - index * 0.13) / 0.74)
          .clamp(0.0, 1.0)
          .toDouble();
      if (phase <= 0 || phase >= 1) continue;
      final opacity = math.sin(math.pi * phase);
      final center = Offset(
        50 + direction * (15 + index * 7),
        30 - phase * (25 + index * 3),
      );
      final heart = Path()
        ..moveTo(center.dx, center.dy + 4)
        ..cubicTo(
          center.dx - 8,
          center.dy - 1,
          center.dx - 5,
          center.dy - 7,
          center.dx,
          center.dy - 3,
        )
        ..cubicTo(
          center.dx + 5,
          center.dy - 7,
          center.dx + 8,
          center.dy - 1,
          center.dx,
          center.dy + 4,
        )
        ..close();
      canvas.drawPath(
        heart,
        Paint()..color = _pink.withValues(alpha: opacity * 0.88),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _KuzaiPetPainter oldDelegate) => true;
}
