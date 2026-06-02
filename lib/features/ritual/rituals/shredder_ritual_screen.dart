import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../../../core/haptics.dart';
import '../../../state/session.dart';
import '../../../theme/app_theme.dart';
import '../../complete/complete_screen.dart';
import '../widgets/paper_card.dart';
import '../widgets/particles.dart';

/// 파쇄 의식 단계.
/// idle → feeding(드래그=투입 트리거) → grinding(3초 자동) → bursting(폭죽) → done.
enum _Phase { idle, feeding, grinding, bursting, done }

// ── 투입/분쇄 임계 상수 (실기기 손맛 기준 미세조정 가능, 명세 §4.3·§11) ──
/// 드래그 중 이 값 도달 시 즉시 grinding 진입.
const double _kFeedThreshold = 0.85;

/// 드래그를 뗀 시점 이 값 이상이면 grinding, 미만이면 idle 리셋.
const double _kFeedCommit = 0.60;

/// 투입 확정 후 고정 분쇄 시간(드래그 속도 무관).
const Duration _kGrindDuration = Duration(milliseconds: 3000);

/// 폭죽 트리거 후 완료 화면 전이까지.
const Duration _kBurstToDone = Duration(milliseconds: 900);

/// RIT-04 파쇄기. 종이를 투입구로 밀어 넣으면 "투입 트리거"가 걸리고,
/// 이후 드래그와 무관하게 3초간 자동 분쇄(연속 strip 낙하 + motor shake +
/// 연속 그라인드 햅틱)된 뒤 종잇조각이 폭죽처럼 터진다.
class ShredderRitualScreen extends StatefulWidget {
  const ShredderRitualScreen({super.key});

  @override
  State<ShredderRitualScreen> createState() => _ShredderRitualScreenState();
}

class _ShredderRitualScreenState extends State<ShredderRitualScreen>
    with TickerProviderStateMixin {
  // 파티클 루프(기존 유지) — 3초 분쇄는 별도 bounded 컨트롤러가 담당.
  late final Ticker _ticker;
  final _field = ParticleField();
  final _repaint = ValueNotifier(0);
  Duration _last = Duration.zero;

  static const _paperSize = Size(240, 320);

  _Phase _phase = _Phase.idle;
  double _feed = 0; // feeding 동안 드래그로만 증가(투입 트리거 판정용).
  double _grind = 0; // grinding 동안 3초 컨트롤러로 0→1(드래그 무관).
  Offset _slot = Offset.zero;

  // 3초 자동 분쇄 컨트롤러(반드시 bounded — unbounded()..repeat() 금지).
  late final AnimationController _grindCtrl;

  // 연속 그라인드 햅틱 핸들(haptics 소유 API, 호출만).
  GrindHandle? _grindHandle;

  // grinding 중 strip 방출 기준점(컨트롤러 value). 매 프레임 과방출 방지.
  double _lastStripAt = 0;
  final math.Random _stripRng = math.Random(0x5117); // 결정적 재현 시드

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
    _grindCtrl = AnimationController(vsync: this, duration: _kGrindDuration)
      ..addListener(_onGrindTick)
      ..addStatusListener(_onGrindStatus);
  }

  void _tick(Duration elapsed) {
    final dt =
        _last == Duration.zero ? 0.016 : (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    _field.update(dt.clamp(0.0, 0.05));
    _repaint.value++;
  }

  // ── 3초 컨트롤러 리스너 ──────────────────────────────────────────────

  void _onGrindTick() {
    if (_phase != _Phase.grinding) return;
    // 종이 흡입을 ease-in-out으로(시작·끝 부드럽게, 중간 가속).
    _grind = Curves.easeInOut.transform(_grindCtrl.value);
    // 햅틱 강도 곡선 동기(haptics 내부에서 §5.3 곡선 적용).
    _grindHandle?.setProgress(_grindCtrl.value);
    _emitGrindStrips();
    setState(() {}); // motor shake 진폭·종이 가시비율 갱신.
  }

  void _onGrindStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _phase == _Phase.grinding) {
      _startBurst();
    }
  }

  // grinding strip 연속 낙하: 컨트롤러 value 구간별 빈도 곡선(§7).
  // 마지막 방출 기준점 대비 value 증가분이 간격을 넘으면 1회 방출(과방출 방지).
  void _emitGrindStrips() {
    final v = _grindCtrl.value; // 0~1 == 0~3.0s
    // 구간별 방출 간격(ms)·조각 수: 초반 촘촘(120ms,4~6) → 후반 성김(220ms,2).
    final double intervalMs;
    final int minCount;
    final int maxCount;
    if (v < 1 / 3) {
      // 0.0~1.0s
      intervalMs = 120;
      minCount = 4;
      maxCount = 6;
    } else if (v < 2 / 3) {
      // 1.0~2.0s
      intervalMs = 160;
      minCount = 3;
      maxCount = 5;
    } else if (v < 0.8) {
      // 2.0~2.4s
      intervalMs = 180;
      minCount = 3;
      maxCount = 4;
    } else if (v < 0.95) {
      // 2.4~2.85s
      intervalMs = 200;
      minCount = 2;
      maxCount = 3;
    } else {
      // 2.85~3.0s
      intervalMs = 220;
      minCount = 2;
      maxCount = 2;
    }
    final intervalT = intervalMs / _kGrindDuration.inMilliseconds;
    if (v - _lastStripAt < intervalT) return;
    _lastStripAt = v;
    final count = minCount + _stripRng.nextInt(maxCount - minCount + 1);
    _field.emitStrip(
      origin: _slot,
      width: _paperSize.width,
      count: count,
      palette: const [AppColors.paper, AppColors.paperShadow],
    );
  }

  // ── 드래그(투입 트리거) ──────────────────────────────────────────────

  void _onDragStart(DragStartDetails d) {
    // feeding 단계에서만 투입 가능. 투입 자체는 조용히(햅틱 없음).
    if (_phase != _Phase.idle && _phase != _Phase.feeding) return;
    _phase = _Phase.feeding;
  }

  void _onDrag(DragUpdateDetails d) {
    if (_phase != _Phase.feeding) return; // grinding/bursting/done 중 입력 무시.
    _feed = (_feed + d.primaryDelta! / _paperSize.height).clamp(0.0, 1.0);

    // 투입량 증가 시 슬릿에서 소량 strip 낙하(투입 피드백, 연속 진동 없음).
    if (_feed > _lastStripAt + 0.02) {
      _lastStripAt = _feed;
      _field.emitStrip(
        origin: _slot,
        width: _paperSize.width,
        count: 2,
        palette: const [AppColors.paper, AppColors.paperShadow],
      );
    }

    // 즉시 투입 트리거: 드래그 중 임계 도달.
    if (_feed >= _kFeedThreshold) {
      _enterGrinding();
      return;
    }
    setState(() {});
  }

  void _onDragEnd(DragEndDetails d) {
    if (_phase != _Phase.feeding) return;
    if (_feed >= _kFeedCommit) {
      _enterGrinding(); // 뗀 시점 커밋 임계 이상 → 분쇄 확정.
    } else {
      // 끝까지 안 넣고 떼면 리셋(강요 없음).
      setState(() {
        _phase = _Phase.idle;
        _feed = 0;
        _lastStripAt = 0;
      });
    }
  }

  // ── 전이: feeding → grinding ────────────────────────────────────────

  void _enterGrinding() {
    if (_phase != _Phase.feeding) return;
    _phase = _Phase.grinding;
    // 진입 시점 _feed 값을 종이 위치로 고정, 이후는 _grind가 주도.
    _grind = _feed;
    _lastStripAt = 0; // grinding strip 방출 기준점 리셋.
    // 연속 그라인드 햅틱 시작(haptics 소유 API).
    _grindHandle = Haptics.instance.startShredGrind();
    // 3초 자동 분쇄 시작.
    _grindCtrl.forward(from: 0);
    setState(() {});
  }

  // ── 전이: grinding → bursting ───────────────────────────────────────

  void _startBurst() {
    if (_phase == _Phase.bursting || _phase == _Phase.done) return;
    _phase = _Phase.bursting;
    _grind = 1.0;

    // §6.2 계약: grind 정지를 burstPop 보다 '반드시 먼저'(겹쳐 뭉개짐 방지).
    _grindHandle?.stop();
    _grindHandle = null;
    Haptics.instance.burstPop();

    // 0ms 시각 폭죽(다색 120 + 삼각 confetti 40 동시).
    _field.emitBurst(
      origin: _slot,
      count: 120,
      palette: _palette,
      speed: 1100,
      spread: 2.4,
      gravity: 900,
    );
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
    // +220ms 잔입자 반짝이(burstPop의 2차 medium 팝과 동기).
    Future.delayed(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      _field.emitBurstSparkle(origin: _slot, count: 50, speed: 480);
    });
    // 폭죽 후 완료 전이.
    Future.delayed(_kBurstToDone, _complete);
    setState(() {});
  }

  void _complete() {
    if (_phase == _Phase.done || !mounted) return;
    _phase = _Phase.done;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) =>
          const CompleteScreen(afterglow: Text('🎊', style: TextStyle(fontSize: 96))),
    ));
  }

  @override
  void dispose() {
    // 누수 0: 진동·타이머·컨트롤러·ticker 모두 정리.
    _grindHandle?.stop();
    _grindCtrl.dispose();
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  // motor shake 변위: grinding 동안 본체를 약 20Hz로 ±진폭만큼 미세 진동.
  // 진폭은 강도 곡선과 동조(§7 진폭표), 3.0s에 0으로 수렴.
  Offset get _motorShake {
    if (_phase != _Phase.grinding) return Offset.zero;
    final v = _grindCtrl.value; // 0~1
    // 진폭 곡선(§7): 0.0→±1.0, 중반 ±1.5 정점, 말미 ±1.2, 3.0s→0.
    final ramp = math.sin(v * math.pi); // 0→1→0 (양 끝 0, 중앙 1)
    final amp = 1.0 + ramp * 0.5; // 1.0~1.5
    // 끝에서 완전히 0으로 페이드(폭죽 직전 정지).
    final fade = (1.0 - v).clamp(0.0, 1.0);
    final osc = math.sin(v * 2 * math.pi * 20 * 3); // 약 20Hz 떨림
    return Offset(osc * amp * fade, osc * 0.4 * amp * fade);
  }

  @override
  Widget build(BuildContext context) {
    final text = SessionScope.of(context).text;
    // 종이 가시 비율 = 1 - max(_feed, _grind).
    final hidden = math.max(_feed, _grind);
    final visible = (1 - hidden).clamp(0.0001, 1.0);
    final paperHidden = _phase == _Phase.bursting || _phase == _Phase.done;
    final shake = _motorShake;

    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, c) {
              final slotY = c.maxHeight * 0.66;
              _slot = Offset(c.maxWidth / 2, slotY);
              final paperTop =
                  slotY - _paperSize.height - 8 + hidden * _paperSize.height;
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
                          heightFactor: visible,
                          child: Opacity(
                            opacity: paperHidden ? 0 : 1,
                            child: PaperCard(
                                text: text,
                                width: _paperSize.width,
                                height: _paperSize.height),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 파쇄기 본체 (grinding 중 motor shake)
                  Positioned(
                    left: 24,
                    right: 24,
                    top: slotY - 18,
                    child: Transform.translate(
                      offset: shake,
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
                  ),
                  // 폭죽 파티클
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(painter: ParticlePainter(_field, _repaint)),
                    ),
                  ),
                  // 안내 카피: grinding 이후엔 숨김(의식 몰입, 강요·설명 금지).
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 40,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 300),
                      opacity:
                          (_phase == _Phase.idle || _phase == _Phase.feeding)
                              ? 1
                              : 0,
                      child: const Text('종이를 투입구로 밀어 넣어요',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white60)),
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
