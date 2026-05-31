import 'package:flutter/material.dart';

import '../../../core/haptics.dart';
import '../../../state/session.dart';
import '../../../theme/app_theme.dart';
import '../../complete/complete_screen.dart';
import '../widgets/paper_card.dart';

/// RIT-10 보석함 보관. 종이를 함에 넣고 뚜껑을 닫으면 뒤로 후광이 빛난다.
/// 소멸이 아닌 '간직'형 의식.
class JewelryBoxRitualScreen extends StatefulWidget {
  const JewelryBoxRitualScreen({super.key});

  @override
  State<JewelryBoxRitualScreen> createState() => _JewelryBoxRitualScreenState();
}

class _JewelryBoxRitualScreenState extends State<JewelryBoxRitualScreen>
    with TickerProviderStateMixin {
  late final AnimationController _lid; // 0(열림) → 1(닫힘)
  late final AnimationController _halo; // 후광
  double _drag = 0; // 종이를 아래로 끈 거리
  bool _inserted = false;
  bool _finished = false;
  static const _approach = 220.0;

  @override
  void initState() {
    super.initState();
    _lid = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
    _halo = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
    _halo.addStatusListener((s) {
      if (s == AnimationStatus.completed) _complete();
    });
  }

  double get _approachT => (_drag / _approach).clamp(0.0, 1.0);

  void _onDrag(DragUpdateDetails d) {
    if (_inserted) return;
    setState(() => _drag = (_drag + d.primaryDelta!).clamp(0.0, _approach));
  }

  void _onDragEnd(DragEndDetails d) {
    if (_inserted) return;
    if (_approachT >= 0.8) {
      _insert();
    } else {
      setState(() => _drag = 0);
    }
  }

  Future<void> _insert() async {
    setState(() => _inserted = true);
    Haptics.instance.fire(HapticLevel.medium, throttle: false); // 함에 넣음
    await Future.delayed(const Duration(milliseconds: 120));
    Haptics.instance.fire(HapticLevel.light); // 뚜껑 닫기 시작
    await _lid.forward();
    Haptics.instance.fire(HapticLevel.medium); // 닫힘
    _halo.forward(); // 후광 → 완료
  }

  void _complete() {
    if (_finished || !mounted) return;
    _finished = true;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => const CompleteScreen(afterglow: _BoxAfterglow()),
    ));
  }

  @override
  void dispose() {
    _lid.dispose();
    _halo.dispose();
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
              final boxCenter = Offset(c.maxWidth / 2, c.maxHeight * 0.68);
              return Stack(
                alignment: Alignment.center,
                children: [
                  // 후광 (Positioned가 Stack 직속이어야 하므로 바깥에 둠)
                  Positioned(
                    left: boxCenter.dx - 160,
                    top: boxCenter.dy - 160,
                    child: AnimatedBuilder(
                      animation: _halo,
                      builder: (_, __) => Container(
                        width: 320,
                        height: 320,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(colors: [
                            AppColors.emberYellow.withValues(alpha: 0.6 * _halo.value),
                            Colors.transparent,
                          ]),
                        ),
                      ),
                    ),
                  ),
                  // 종이 (끌어내릴수록 작아지며 함으로)
                  if (!_inserted)
                    Positioned(
                      top: c.maxHeight * 0.42 - 160 + _drag,
                      child: GestureDetector(
                        onVerticalDragUpdate: _onDrag,
                        onVerticalDragEnd: _onDragEnd,
                        child: Transform.scale(
                          scale: 1 - _approachT * 0.5,
                          child: PaperCard(text: text, width: 220, height: 300),
                        ),
                      ),
                    ),
                  // 보석함
                  Positioned(
                    left: boxCenter.dx - 90,
                    top: boxCenter.dy - 40,
                    child: _JewelryBox(lid: _lid),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 40,
                    child: Text(
                      _inserted ? '소중히 간직할게요' : '종이를 보석함으로 끌어내려요',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white60),
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

class _JewelryBox extends StatelessWidget {
  const _JewelryBox({required this.lid});
  final Animation<double> lid;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: lid,
      builder: (_, __) {
        return SizedBox(
          width: 180,
          height: 120,
          child: Stack(
            alignment: Alignment.bottomCenter,
            children: [
              // 함 본체
              Container(
                width: 180,
                height: 90,
                decoration: BoxDecoration(
                  color: const Color(0xFF6B4E8A),
                  borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
                  border: Border.all(color: AppColors.emberYellow.withValues(alpha: 0.6)),
                ),
              ),
              // 뚜껑 (열림→닫힘: 위로 들렸다가 내려옴)
              Positioned(
                top: (1 - lid.value) * -54,
                child: Transform(
                  alignment: Alignment.bottomCenter,
                  transform: Matrix4.identity()
                    ..rotateX((1 - lid.value) * 0.9),
                  child: Container(
                    width: 186,
                    height: 40,
                    decoration: BoxDecoration(
                      color: const Color(0xFF7E5BA6),
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                      border: Border.all(color: AppColors.emberYellow.withValues(alpha: 0.7)),
                    ),
                    child: const Center(child: Text('💎', style: TextStyle(fontSize: 20))),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// END-01 보석함 마무리: 예쁜 곳에 안치 + 후광.
class _BoxAfterglow extends StatelessWidget {
  const _BoxAfterglow();
  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 1000),
      builder: (_, v, __) => Container(
        width: 200,
        height: 200,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [
            AppColors.emberYellow.withValues(alpha: 0.5 * v),
            Colors.transparent,
          ]),
        ),
        child: const Text('💝', style: TextStyle(fontSize: 84)),
      ),
    );
  }
}
