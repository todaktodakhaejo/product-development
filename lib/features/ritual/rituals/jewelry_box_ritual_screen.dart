import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../../../core/haptics.dart';
import '../../../state/session.dart';
import '../../../theme/app_theme.dart';
import '../../complete/complete_screen.dart';
import '../widgets/paper_card.dart';
import '../widgets/particles.dart';

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
  late final Ticker _ticker; // 파티클 60fps 구동
  late final Animation<double> _lidCurve; // 스프링 닫힘(easeOutBack)
  Duration _lastTick = Duration.zero; // dt 산출용
  final _field = ParticleField(maxParticles: 120); // sparkle는 적게
  final _repaint = ValueNotifier(0);
  double _drag = 0; // 종이를 아래로 끈 거리
  bool _inserted = false;
  bool _finished = false;
  bool _snapped = false; // 스냅 햅틱 1회만 발사하기 위한 가드
  Offset _boxCenter = Offset.zero; // 함 입구 좌표(sparkle origin)
  static const _approach = 220.0;

  @override
  void initState() {
    super.initState();
    _lid = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
    // 점잖은 1회 오버슈트(keep 톤). elasticOut은 진폭 과다라 비권장.
    _lidCurve = CurvedAnimation(parent: _lid, curve: Curves.easeOutBack);
    _halo = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
    _halo.addStatusListener((s) {
      if (s == AnimationStatus.completed) _complete();
    });
    // 파티클 갱신용 틱(burn·shredder와 동일하게 Ticker 사용).
    // ※ AnimationController.unbounded + repeat()는 lowerBound가 -∞라
    //   '_initialT >= 0.0' assertion으로 크래시 → Ticker로 직접 구동한다.
    _ticker = createTicker(_onTick)..start();
  }

  /// 매 프레임 파티클 적분 + 리페인트. dt는 직전 프레임과의 실제 경과.
  void _onTick(Duration elapsed) {
    final dt = _lastTick == Duration.zero
        ? 0.016
        : (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    _field.update(dt.clamp(0.0, 0.05));
    _repaint.value++;
  }

  double get _approachT => (_drag / _approach).clamp(0.0, 1.0);

  void _onDrag(DragUpdateDetails d) {
    if (_inserted) return;
    setState(() => _drag = (_drag + d.primaryDelta!).clamp(0.0, _approach));
    // 함 근처 임계 진입 순간 1회만 부드러운 스냅 햅틱(자석처럼 살짝 끌림).
    if (!_snapped && _approachT >= 0.8) {
      _snapped = true;
      Haptics.instance.fire(HapticLevel.selection);
    } else if (_snapped && _approachT < 0.8) {
      _snapped = false; // 다시 멀어지면 재무장
    }
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
    // 안치 순간: 부드러운 안착 + 금빛 반짝이.
    Haptics.instance.fire(HapticLevel.light, throttle: false);
    _field.emitSparkle(origin: _boxCenter, count: 18, radius: 60);
    await Future.delayed(const Duration(milliseconds: 120));
    await _lid.forward(); // 스프링(easeOutBack) 닫힘
    if (!mounted) return;
    // 뚜껑 닫힘 마무리: heavy 단발 금지 → 부드러운 2펄스(keep 톤).
    Haptics.instance.softSuccess();
    // 닫힘 직후 작게 한 번 더 반짝.
    _field.emitSparkle(origin: _boxCenter, count: 10, radius: 40);
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
    _ticker.dispose(); // 파티클 틱 누수 방지
    _repaint.dispose();
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
              _boxCenter = boxCenter; // sparkle origin(함 입구)
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
                    child: _JewelryBox(lid: _lidCurve),
                  ),
                  // sparkle 파티클(안치 반짝이)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(painter: ParticlePainter(_field, _repaint)),
                    ),
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
