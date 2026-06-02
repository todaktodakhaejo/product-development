import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../../../core/haptics.dart';
import '../../../state/session.dart';
import '../../../theme/app_theme.dart';
import '../../complete/complete_screen.dart';
import '../widgets/paper_card.dart';
import '../widgets/particles.dart';

/// RIT-01 태우기. 아래에서 불씨를 끌어올리면 종이가 아래→위로 타오르고,
/// 진행도에 맞춰 햅틱도 아래→위로 점점 강해진다.
class BurnRitualScreen extends StatefulWidget {
  const BurnRitualScreen({super.key});

  @override
  State<BurnRitualScreen> createState() => _BurnRitualScreenState();
}

class _BurnRitualScreenState extends State<BurnRitualScreen>
    with TickerProviderStateMixin {
  late final AnimationController _burn; // 0(바닥) → 1(전소)
  late final VoidCallback _detachHaptics;
  late final Ticker _ticker;
  final _field = ParticleField();
  final _repaint = ValueNotifier(0);
  Duration _last = Duration.zero;

  static const _paperSize = Size(250, 340);
  Rect _paperRect = Rect.zero;
  bool _finished = false;
  double _emitAccum = 0; // 재·연기 방출 throttle 누적기(매 프레임 방출 방지)

  @override
  void initState() {
    super.initState();
    _burn = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));
    // 아래→위로 번지는 햅틱: 비감소 5큐(light→…→heavy). 시작이 가장 약하고 끝이 최고조.
    _detachHaptics = Haptics.instance.playTimeline(_burn, Haptics.burnTimeline());
    _ticker = createTicker(_tick)..start();
  }

  void _tick(Duration elapsed) {
    final dt = _last == Duration.zero ? 0.016 : (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    // 타는 동안 불씨(상승)·재(하강)·연기(상승)를 현재 불 경계 y에서 방출.
    if (_burn.value > 0 && _burn.value < 1 && _paperRect != Rect.zero) {
      final burnY = _paperRect.bottom - _paperRect.height * _burn.value;
      final origin = Offset(_paperRect.center.dx, burnY);
      // ember: 매 프레임 소량(기존 유지).
      _field.emitEmber(
        origin: origin,
        count: 3,
        palette: const [AppColors.emberOrange, AppColors.emberYellow, Color(0xFFFF5722)],
      );
      // ash + smoke: 약 120ms마다(throttle) — 매 프레임 방출 시 입자 폭증 방지.
      _emitAccum += dt;
      if (_emitAccum >= 0.12) {
        _emitAccum = 0;
        _field.emitAsh(origin: origin, count: 2); // 검게 식은 재 하강
        _field.emitSmoke(origin: origin, count: 1); // 옅은 연기 상승
      }
    }
    _field.update(dt.clamp(0.0, 0.05));
    _repaint.value++;
  }

  void _onDrag(DragUpdateDetails d) {
    if (_finished) return;
    // 위로 끌수록 진행. 종이 높이를 기준으로 정규화.
    _burn.value = (_burn.value - d.primaryDelta! / _paperSize.height).clamp(0.0, 1.0);
    if (_burn.value >= 1.0) _complete();
  }

  void _onDragEnd(DragEndDetails d) {
    if (_finished) return;
    if (_burn.value > 0.45) {
      _burn.animateTo(1.0, curve: Curves.easeIn).whenComplete(_complete);
    } else {
      _burn.animateBack(0.0, curve: Curves.easeOut);
    }
  }

  void _complete() {
    if (_finished) return;
    _finished = true;
    // 전소 마무리: heavy 단발이 아니라 잦아드는 잔불 같은 부드러운 마무리.
    Haptics.instance.softSuccess();
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => const CompleteScreen(afterglow: _CandleAfterglow()),
    ));
  }

  @override
  void dispose() {
    _detachHaptics();
    _burn.dispose();
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = SessionScope.of(context).text;
    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, c) {
              _paperRect = Rect.fromCenter(
                center: Offset(c.maxWidth / 2, c.maxHeight * 0.42),
                width: _paperSize.width,
                height: _paperSize.height,
              );
              return Stack(
                children: [
                  // 종이: 아래가 타들어가 위쪽만 남음 + 하단 탄 자국 그라데이션.
                  Positioned.fromRect(
                    rect: _paperRect,
                    child: AnimatedBuilder(
                      animation: _burn,
                      builder: (_, __) => ClipRect(
                        child: Align(
                          alignment: Alignment.topCenter,
                          heightFactor: (1 - _burn.value).clamp(0.0001, 1.0),
                          child: Stack(
                            children: [
                              PaperCard(
                                  text: text,
                                  width: _paperSize.width,
                                  height: _paperSize.height),
                              // 탄 자국: 남은 종이의 하단(연소선 쪽)이 점점 검게.
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(8),
                                      gradient: LinearGradient(
                                        begin: Alignment.bottomCenter,
                                        end: Alignment.topCenter,
                                        colors: [
                                          kAshGray.withValues(alpha: 0.85 * _burn.value),
                                          kAshGray.withValues(alpha: 0.0),
                                        ],
                                        stops: const [0.0, 0.4],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 연소선(char 글로우 띠 + 불꽃 혀) — 종이 영역 위에 겹쳐 그림.
                  Positioned.fromRect(
                    rect: _paperRect,
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: BurnLinePainter(
                            burnValueOf: () => _burn.value, repaint: _repaint),
                      ),
                    ),
                  ),
                  // 불씨 파티클
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(painter: ParticlePainter(_field, _repaint)),
                    ),
                  ),
                  // 안내 + 드래그 핸들
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 48,
                    child: GestureDetector(
                      onVerticalDragUpdate: _onDrag,
                      onVerticalDragEnd: _onDragEnd,
                      behavior: HitTestBehavior.opaque,
                      child: const Column(
                        children: [
                          Icon(Icons.local_fire_department, color: AppColors.emberOrange, size: 40),
                          SizedBox(height: 8),
                          Text('불씨를 위로 끌어올려 태워요',
                              style: TextStyle(color: Colors.white60)),
                        ],
                      ),
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

/// 연소선 painter: 남은 종이 하단 경계에 char 글로우 띠 + 흔들리는 불꽃 혀.
/// 진행값은 [burnValueOf]로 매 프레임 읽고, repaint는 화면 틱(_repaint)에 묶어
/// 불꽃 혀가 항상 미세하게 살아 있도록(idle 흔들림) 한다.
class BurnLinePainter extends CustomPainter {
  BurnLinePainter({required this.burnValueOf, required Listenable repaint})
      : super(repaint: repaint);

  /// 현재 연소 진행값(0→1)을 반환. 매 frame paint 시 최신값을 읽기 위한 콜백.
  final double Function() burnValueOf;

  @override
  void paint(Canvas canvas, Size size) {
    final progress = burnValueOf();
    if (progress <= 0 || progress >= 1) return;
    // 아래→위로 타므로 연소선 Y = 남은 종이의 하단 경계.
    final y = size.height * (1 - progress);

    // 1) char 글로우 띠: emberOrange→emberYellow 가로 그라데이션 + blur.
    final glow = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8)
      ..shader = const LinearGradient(
        colors: [
          AppColors.emberOrange,
          AppColors.emberYellow,
          AppColors.emberOrange,
        ],
      ).createShader(Rect.fromLTWH(0, y - 6, size.width, 12));
    canvas.drawRect(Rect.fromLTWH(0, y - 4, size.width, 8), glow);

    // 2) 불꽃 혀: 연소선 위로 솟는 작은 sin 파형(매 프레임 위상 변동으로 살아 있음).
    final flame = Paint()..color = AppColors.emberYellow.withValues(alpha: 0.85);
    const tongues = 9;
    final path = Path()..moveTo(0, y);
    for (var i = 0; i <= tongues; i++) {
      final x = size.width * i / tongues;
      final h = 10 + 8 * (0.5 + 0.5 * sin(i * 1.7 + progress * 20));
      path.lineTo(x, y - h);
      path.lineTo(size.width * (i + 0.5) / tongues, y);
    }
    path.lineTo(size.width, y);
    canvas.drawPath(path, flame);
  }

  @override
  bool shouldRepaint(covariant BurnLinePainter old) => true;
}

/// END-01 태우기 마무리: 잔잔한 촛불.
class _CandleAfterglow extends StatelessWidget {
  const _CandleAfterglow();
  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.85, end: 1.0),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeInOut,
      builder: (_, v, __) => Opacity(
        opacity: 1,
        child: Transform.scale(scale: v, child: const Text('🕯️', style: TextStyle(fontSize: 96))),
      ),
    );
  }
}
