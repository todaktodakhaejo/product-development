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

  static const _palette = [
    AppColors.ballCore,
    AppColors.emberYellow,
    Color(0xFFFF8AB3),
    Color(0xFF8FE3B0),
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

  void _onDrag(DragUpdateDetails d) {
    if (_bursting) return;
    final prev = _feed;
    _feed = (_feed + d.primaryDelta! / _paperSize.height).clamp(0.0, 1.0);
    if (_feed > prev) Haptics.instance.fire(HapticLevel.light); // 투입 진동
    setState(() {});
    if (_feed >= 1.0) _burst();
  }

  void _onDragEnd(DragEndDetails d) {
    if (_bursting || _feed >= 1.0) return;
    setState(() => _feed = 0); // 덜 넣으면 되돌아옴
  }

  void _burst() {
    if (_bursting) return;
    _bursting = true;
    Haptics.instance.fire(HapticLevel.heavy, throttle: false);
    _field.emitBurst(
      origin: _slot,
      count: 120,
      palette: _palette,
      speed: 1100,
      spread: 2.4,
      gravity: 900,
    );
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
