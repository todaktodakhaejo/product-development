import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../../../core/haptics.dart';
import '../../../state/session.dart';
import '../../../theme/app_theme.dart';
import '../../complete/complete_screen.dart';
import '../widgets/paper_card.dart';
import '../widgets/particles.dart';

/// RIT-04 파쇄기. 종이를 투입구로 끌어내리면 진동하며 빨려 들어가고,
/// 다 파쇄되면 종잇조각이 폭죽처럼 터진다.
class ShredderRitualScreen extends StatefulWidget {
  const ShredderRitualScreen({super.key});

  @override
  State<ShredderRitualScreen> createState() => _ShredderRitualScreenState();
}

class _ShredderRitualScreenState extends State<ShredderRitualScreen>
    with TickerProviderStateMixin {
  late final Ticker _ticker;
  final _field = ParticleField();
  final _repaint = ValueNotifier(0);
  Duration _last = Duration.zero;

  static const _paperSize = Size(240, 320);
  double _feed = 0; // 0(원형) → 1(전부 투입)
  bool _bursting = false;
  bool _finished = false;
  Offset _slot = Offset.zero;

  RumbleHandle? _rumble; // 투입 중 '갈리는' 연속 진동(드래그 동안만)
  double _lastFeed = 0; // strip 방출 기준점

  static const _palette = [
    AppColors.ballCore,
    AppColors.emberYellow,
    kConfettiPink,
    kConfettiMint,
    AppColors.ballGlow,
  ];

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick)..start();
  }

  void _tick(Duration elapsed) {
    final dt = _last == Duration.zero ? 0.016 : (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    _field.update(dt.clamp(0.0, 0.05));
    _repaint.value++;
  }

  // 투입 시작: 연속 rumble 시작('갈리는' 질감). 드래그 동안만 울리고 끝에서 멈춘다.
  void _onDragStart(DragStartDetails d) {
    if (_bursting) return;
    _rumble ??= Haptics.instance.rumble(intensity: 0.4);
  }

  void _onDrag(DragUpdateDetails d) {
    if (_bursting) return;
    _feed = (_feed + d.primaryDelta! / _paperSize.height).clamp(0.0, 1.0);

    // 투입 속도(px/s)를 0~1로 정규화해 rumble 강도에 반영(빠를수록 강·촘촘).
    final speed = d.primaryDelta!.abs() * 60; // delta/frame → 대략 px/s
    final norm = (speed / 2000).clamp(0.0, 1.0);
    _rumble?.setIntensity(norm);

    // 투입량 증가분이 임계를 넘으면 슬릿에서 세로 스트립 조각 낙하.
    final df = _feed - _lastFeed;
    if (df > 0.015) {
      _lastFeed = _feed;
      final strips = (2 + df * 30).round().clamp(2, 8);
      _field.emitStrip(
        origin: _slot,
        width: _paperSize.width,
        count: strips,
        palette: const [AppColors.paper, AppColors.paperShadow],
      );
    }

    setState(() {});
    if (_feed >= 1.0) _burst();
  }

  void _onDragEnd(DragEndDetails d) {
    // 끝까지 안 넣고 떼면 rumble을 멈추고 종이 리셋(강요 없음).
    if (_bursting || _feed >= 1.0) {
      _rumble?.stop();
      _rumble = null;
      return;
    }
    _rumble?.stop();
    _rumble = null;
    setState(() {
      _feed = 0;
      _lastFeed = 0;
    });
  }

  void _burst() {
    if (_bursting) return;
    _bursting = true;
    // 투입 rumble 종료.
    _rumble?.stop();
    _rumble = null;
    // 완료 더블탭: medium 즉시 + success 살짝 뒤(폭죽감).
    Haptics.instance.fire(HapticLevel.medium, throttle: false);
    Future.delayed(const Duration(milliseconds: 80), () {
      Haptics.instance.fire(HapticLevel.success, throttle: false);
    });
    // 1차 폭죽(기존 유지, 다색 강화).
    _field.emitBurst(
      origin: _slot,
      count: 120,
      palette: _palette,
      speed: 1100,
      spread: 2.4,
      gravity: 900,
    );
    // 색종이 삼각 조각 추가(조금 더 크고 천천히).
    _field.emitBurst(
      origin: _slot,
      count: 40,
      palette: const [kConfettiPink, kConfettiMint, AppColors.emberYellow],
      speed: 600,
      sizeMin: 6,
      sizeMax: 14,
      spread: 2.0,
      gravity: 700,
      shape: ParticleShape.triangle,
    );
    // 2차 잔입자 반짝이: 220ms 뒤.
    Future.delayed(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      _field.emitBurstSparkle(origin: _slot, count: 50, speed: 480);
    });
    Future.delayed(const Duration(milliseconds: 900), _complete);
  }

  void _complete() {
    if (_finished || !mounted) return;
    _finished = true;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => const CompleteScreen(afterglow: Text('🎊', style: TextStyle(fontSize: 96))),
    ));
  }

  @override
  void dispose() {
    _rumble?.stop(); // 드래그 중 화면 이탈 대비(무한 진동·타이머 누수 방지)
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
              final slotY = c.maxHeight * 0.66;
              _slot = Offset(c.maxWidth / 2, slotY);
              final paperTop = slotY - _paperSize.height - 8 + _feed * _paperSize.height;
              return Stack(
                children: [
                  // 투입되는 종이 (아래가 슬롯에 잠겨 사라짐)
                  Positioned(
                    left: (c.maxWidth - _paperSize.width) / 2,
                    top: paperTop,
                    width: _paperSize.width,
                    child: GestureDetector(
                      onVerticalDragStart: _onDragStart,
                      onVerticalDragUpdate: _onDrag,
                      onVerticalDragEnd: _onDragEnd,
                      child: ClipRect(
                        child: Align(
                          alignment: Alignment.topCenter,
                          heightFactor: (1 - _feed).clamp(0.0001, 1.0),
                          child: Opacity(
                            opacity: _bursting ? 0 : 1,
                            child: PaperCard(text: text, width: _paperSize.width, height: _paperSize.height),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 파쇄기 본체
                  Positioned(
                    left: 24,
                    right: 24,
                    top: slotY - 18,
                    child: Container(
                      height: 56,
                      decoration: BoxDecoration(
                        color: const Color(0xFF22242E),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Center(
                        child: Container(
                          width: _paperSize.width + 16,
                          height: 6,
                          decoration: BoxDecoration(
                            color: Colors.black,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 폭죽 파티클
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(painter: ParticlePainter(_field, _repaint)),
                    ),
                  ),
                  const Positioned(
                    left: 0,
                    right: 0,
                    bottom: 40,
                    child: Text('종이를 투입구로 밀어 넣어요',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white60)),
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
