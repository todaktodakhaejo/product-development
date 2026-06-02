import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../../../core/haptics.dart';
import '../../../core/strings.dart';
import '../../../state/session.dart';
import '../../../theme/app_theme.dart';
import '../widgets/paper_card.dart';
import '../widgets/particles.dart';

/// 파쇄 의식 단계.
/// idle → feeding(드래그=투입 트리거) → grinding(3초 자동) → bursting(~3초 폭죽
/// 연쇄) → done(인플레이스 완료 멘트·버튼). 태우기와 동일한 인플레이스 완료 —
/// 라우트 전환 없이 같은 파쇄기 화면에 머문다.
enum _Phase { idle, feeding, grinding, bursting, done }

// ── 투입/분쇄 임계 상수 (실기기 손맛 기준 미세조정 가능, 명세 §4.3·§11) ──
/// 드래그 중 이 값 도달 시 즉시 grinding 진입.
const double _kFeedThreshold = 0.85;

/// 드래그를 뗀 시점 이 값 이상이면 grinding, 미만이면 idle 리셋.
const double _kFeedCommit = 0.60;

/// 투입 확정 후 고정 분쇄 시간(드래그 속도 무관).
const Duration _kGrindDuration = Duration(milliseconds: 3000);

// ── 폭죽 피날레 / 인플레이스 완료 타임라인(폭죽 시작=0 기준) ────────────────
/// 시각 폭죽 연쇄가 ~3초간 팡!…팡팡!! 터지는 총 길이. 이 시간이 지나야
/// 완료 멘트가 떠오른다(폭죽이 가라앉을 여유 +0.2s 포함). 병렬로 추가되는
/// `Haptics.fireworksFinale()`의 3초 햅틱 시퀀스와 길이를 맞춘다.
const Duration _kFinaleDur = Duration(milliseconds: 3200);

/// 폭죽이 가라앉은 뒤 파쇄기 본체가 완전히 사라지는 페이드(이게 끝난 다음 멘트).
const Duration _kMachineFade = Duration(milliseconds: 600);

/// 완료 멘트가 다 뜬 뒤 '처음으로' 버튼이 떠오르기까지의 추가 지연
/// 본체 소멸→멘트 페이드인이 끝난 뒤 '처음으로' 버튼(폭죽 시작 기준 ≈5.4s).
const Duration _kButtonDelay = Duration(milliseconds: 5400);

/// 완료 멘트 페이드인 시간(opacity 0→1, ease).
const Duration _kMessageFade = Duration(milliseconds: 1300);

/// '처음으로' 버튼 페이드인 시간(opacity 0→1).
const Duration _kButtonFade = Duration(milliseconds: 800);

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

  // ── 완료 인플레이스 오버레이 시퀀스 토글(폭죽 후 Future.delayed로 구동) ──
  bool _hideMachine = false; // 폭죽 시작 +≈3.2s 파쇄기 본체 페이드아웃 시작.
  bool _showMessage = false; // 본체 소멸 후 +≈3.8s 멘트 페이드인.
  bool _showButton = false; // +≈5.4s '처음으로' 버튼 페이드인.

  double _feed = 0; // feeding 동안 드래그로만 증가(투입 트리거 판정용).
  double _grind = 0; // grinding 동안 3초 컨트롤러로 0→1(드래그 무관).
  double _feedAtGrindStart = 0; // grinding 진입 시 투입 강도(햅틱 연속용 기준점).
  Offset _slot = Offset.zero;

  // 3초 자동 분쇄 컨트롤러(반드시 bounded — unbounded()..repeat() 금지).
  late final AnimationController _grindCtrl;

  // 연속 그라인드 햅틱 핸들(haptics 소유 API, 호출만).
  GrindHandle? _grindHandle;

  // grinding 중 strip 방출 기준점(컨트롤러 value). 매 프레임 과방출 방지.
  double _lastStripAt = 0;
  final math.Random _stripRng = math.Random(0x5117); // 결정적 재현 시드
  // 폭죽 연쇄 위치/입자 jitter용 결정적 시드(파티클 결정적 재현).
  final math.Random _burstRng = math.Random(0xF1E5); // "fires"

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
    // 햅틱 강도 곡선 동기(haptics 내부에서 §5.3 곡선 적용). 투입 단계서 이어받은
    // 강도(_feedAtGrindStart)에서 1.0까지 연속 상승 — 투입↔분쇄 사이 끊김 없음.
    _grindHandle
        ?.setProgress(_feedAtGrindStart + (1 - _feedAtGrindStart) * _grindCtrl.value);
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

    // 투입량 증가 시 슬릿에서 소량 strip 낙하(투입 피드백).
    if (_feed > _lastStripAt + 0.02) {
      _lastStripAt = _feed;
      // 종이가 파쇄기로 들어가는(이빨에 닿는) 순간부터 갈리는 햅틱 시작.
      _grindHandle ??= Haptics.instance.startShredGrind();
      _field.emitStrip(
        origin: _slot,
        width: _paperSize.width,
        count: 2,
        palette: const [AppColors.paper, AppColors.paperShadow],
      );
    }
    // 투입량(_feed)에 비례해 갈림 강도 상승(더 밀어넣을수록 세게).
    _grindHandle?.setProgress(_feed);

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
      // 끝까지 안 넣고 떼면 리셋(강요 없음) — 투입 중 시작된 갈림 햅틱도 정지.
      _grindHandle?.stop();
      _grindHandle = null;
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
    // 투입 단계서 이미 시작된 갈림 강도를 이어받아 끊김 없이 1.0까지 상승.
    _feedAtGrindStart = _feed;
    // 투입 중 이미 켜졌으면 유지, 아니면(임계 즉시도달 등) 지금 시작.
    _grindHandle ??= Haptics.instance.startShredGrind();
    // 3초 자동 분쇄 시작.
    _grindCtrl.forward(from: 0);
    setState(() {});
  }

  // ── 전이: grinding → bursting ───────────────────────────────────────

  void _startBurst() {
    if (_phase == _Phase.bursting || _phase == _Phase.done) return;
    _phase = _Phase.bursting;
    _grind = 1.0;

    // §6.2 계약: grind 정지를 폭죽 햅틱보다 '반드시 먼저'(겹쳐 뭉개짐 방지).
    _grindHandle?.stop();
    _grindHandle = null;
    // 폭죽 햅틱: 병렬로 추가되는 3초 진동 시퀀스를 1회 호출(기존 burstPop 대체).
    // 시각 폭죽 연쇄(~3초)와 길이를 맞춰 팡!…팡팡!! 진동이 함께 간다.
    Haptics.instance.fireworksFinale();

    // ── 0ms: 1차 큰 폭죽(다색 120 + 삼각 confetti 40 동시) ──
    _bigBurst();

    // ── 0~3s: 작은 폭죽들이 staggered로 연달아(팡!…팡팡!!) ──
    // 결정적 시점·시드로 여러 번 터뜨린다. 중간중간 2~3발이 겹치는 '팡팡!!'
    // 구간을 두어 폭죽다운 리듬을 만든다(완전 균일 X). 큰 폭죽 1발도 후반에 재투입.
    _scheduleBurst(550, small: true);
    _scheduleBurst(720, small: true); // 팡팡(겹침)
    _scheduleBurst(1100, big: true); // 중반 큰 폭죽 재점화
    _scheduleBurst(1500, small: true);
    _scheduleBurst(1640, small: true); // 팡팡(겹침)
    _scheduleBurst(1780, small: true); // 팡팡팡(3연)
    _scheduleBurst(2200, small: true);
    _scheduleBurst(2550, big: true); // 후반 큰 폭죽
    _scheduleBurst(2700, small: true); // 잔불꽃
    _scheduleBurst(2880, small: true);

    // ── ≈3.2s: 폭죽이 가라앉으면 '먼저' 파쇄기 본체를 비운다(페이드아웃) ──
    Future.delayed(_kFinaleDur, () {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.done;
        _hideMachine = true; // 본체 페이드아웃 시작(_kMachineFade).
      });
    });
    // ── ≈3.8s: 본체가 '완전히 사라진 뒤' 완료 멘트 페이드인(+success 1회) ──
    Future.delayed(_kFinaleDur + _kMachineFade, () {
      if (!mounted) return;
      // 멘트가 떠오르는 순간 부드러운 success 햅틱 1회(태우기 완료 톤과 동일).
      Haptics.instance.fire(HapticLevel.success, throttle: false);
      setState(() => _showMessage = true);
    });
    // ── ≈4.5s: '처음으로' 버튼 페이드인 ──
    Future.delayed(_kButtonDelay, () {
      if (!mounted) return;
      setState(() => _showButton = true);
    });
    setState(() {});
  }

  // 큰 폭죽 1발: 다색 120 + 삼각 confetti 40 + 반짝이 잔입자(+170ms).
  void _bigBurst() {
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
    Future.delayed(const Duration(milliseconds: 170), () {
      if (!mounted) return;
      _field.emitBurstSparkle(origin: _slot, count: 50, speed: 480);
    });
  }

  // 작은 폭죽 1발: 슬롯 주변에서 살짝 흩어진 위치에 팡! (결정적 시드).
  // 큰 폭죽보다 적은 입자·느린 속도로 '잔폭죽' 느낌. 위치 jitter로 매번 다른 곳.
  void _smallBurst() {
    final jx = (_burstRng.nextDouble() - 0.5) * 160;
    final jy = (_burstRng.nextDouble() - 0.5) * 120 - 30; // 살짝 위쪽 편향
    final origin = _slot + Offset(jx, jy);
    _field.emitBurst(
      origin: origin,
      count: 36 + _burstRng.nextInt(24), // 36~59
      palette: _palette,
      speed: 560 + _burstRng.nextDouble() * 240, // 560~800
      spread: 2.4,
      gravity: 760,
    );
    _field.emitBurstSparkle(origin: origin, count: 18, speed: 360);
  }

  // 폭죽 1발을 delayMs 뒤 예약(mounted 가드). big/small 택1.
  void _scheduleBurst(int delayMs, {bool big = false, bool small = false}) {
    Future.delayed(Duration(milliseconds: delayMs), () {
      if (!mounted || _phase == _Phase.done) return;
      if (big) {
        _bigBurst();
      } else {
        _smallBurst();
      }
    });
  }

  // ── '처음으로': 세션 리셋 + 홈 복귀(태우기 _backToHome와 동일) ──
  void _backToHome() {
    SessionScope.of(context).reset();
    Navigator.of(context).popUntil((r) => r.isFirst);
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
                  // "다 보냈어요" 멘트가 뜨면(_showMessage) 본체도 함께 사라진다 —
                  // 폭죽·재만 남기고 기계는 비워 완료의 여운을 방해하지 않게.
                  Positioned(
                    left: 24,
                    right: 24,
                    top: slotY - 18,
                    child: AnimatedOpacity(
                      duration: _kMachineFade,
                      curve: Curves.easeInOut,
                      opacity: _hideMachine ? 0.0 : 1.0,
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

                  // ── 완료 멘트(인플레이스 페이드인) — 화면 중앙 ──
                  // 태우기와 동일 카피·스타일. 폭죽 위 가독성 위해 그림자.
                  // 멘트가 다 떠야 버튼이 뜨므로 IgnorePointer.
                  if (_phase == _Phase.done)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: AnimatedOpacity(
                          duration: _kMessageFade,
                          curve: Curves.easeInOut,
                          opacity: _showMessage ? 1.0 : 0.0,
                          child: const Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  kCompletionMessage,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 26,
                                    fontWeight: FontWeight.w700,
                                    shadows: [
                                      Shadow(
                                        blurRadius: 12,
                                        color: Color(0x99000000),
                                      ),
                                    ],
                                  ),
                                ),
                                SizedBox(height: 12),
                                Text(
                                  '잘 보냈어요. 마음이 조금 가벼워졌길.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Colors.white60,
                                    shadows: [
                                      Shadow(
                                        blurRadius: 10,
                                        color: Color(0x80000000),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),

                  // ── '처음으로' 버튼(멘트 뒤 페이드인) — 하단 고정 ──
                  if (_phase == _Phase.done)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: AnimatedOpacity(
                        duration: _kButtonFade,
                        curve: Curves.easeInOut,
                        opacity: _showButton ? 1.0 : 0.0,
                        child: IgnorePointer(
                          ignoring: !_showButton,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(32, 0, 32, 36),
                            child: SizedBox(
                              width: double.infinity,
                              child: FilledButton(
                                onPressed: _backToHome,
                                style: FilledButton.styleFrom(
                                  backgroundColor: AppColors.ballGlow,
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 16),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                child: const Text('처음으로'),
                              ),
                            ),
                          ),
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
