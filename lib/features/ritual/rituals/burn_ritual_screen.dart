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

  @override
  void initState() {
    super.initState();
    _burn = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));
    // 아래→위로 번지는 햅틱
    _detachHaptics = Haptics.instance.playTimeline(_burn, const [
      HapticCue(0.02, HapticLevel.light),
      HapticCue(0.3, HapticLevel.light),
      HapticCue(0.55, HapticLevel.medium),
      HapticCue(0.8, HapticLevel.medium),
      HapticCue(0.98, HapticLevel.success),
    ]);
    _ticker = createTicker(_tick)..start();
  }

  void _tick(Duration elapsed) {
    final dt = _last == Duration.zero ? 0.016 : (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    // 타는 동안 불씨 방출 (현재 불 경계 y)
    if (_burn.value > 0 && _burn.value < 1 && _paperRect != Rect.zero) {
      final burnY = _paperRect.bottom - _paperRect.height * _burn.value;
      _field.emitEmber(
        origin: Offset(_paperRect.center.dx, burnY),
        count: 3,
        palette: const [AppColors.emberOrange, AppColors.emberYellow, Color(0xFFFF5722)],
      );
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
                  // 종이: 아래가 타들어가 위쪽만 남음
                  Positioned.fromRect(
                    rect: _paperRect,
                    child: AnimatedBuilder(
                      animation: _burn,
                      builder: (_, __) => ClipRect(
                        child: Align(
                          alignment: Alignment.topCenter,
                          heightFactor: (1 - _burn.value).clamp(0.0001, 1.0),
                          child: PaperCard(
                              text: text,
                              width: _paperSize.width,
                              height: _paperSize.height),
                        ),
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
