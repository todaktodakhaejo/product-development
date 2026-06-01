import 'dart:math';

import 'package:flutter/material.dart';

import '../../../core/haptics.dart';
import '../../../core/strings.dart';
import '../../../state/session.dart';
import '../../../theme/app_theme.dart';
import '../widgets/paper_card.dart';
import '../widgets/paper_plane_glyph.dart';

// ── 종이비행기 상태머신 ────────────────────────────────────────────────────
/// idle → folding(3단계 자동 접기) → folded(던지기 대기) → flying(글라이드) →
/// done(인플레이스 완료 멘트→버튼). 라우트 전환 없음(태우기 패턴).
enum _Phase { idle, folding, folded, flying, done }

/// 접기 시퀀스 총 길이(3구간: center crease / nose / wings).
const Duration _kFoldDuration = Duration(milliseconds: 1500);

/// 비행 글라이드 길이(또렷한 궤적을 그리며 먼 하늘로 후퇴 — 최소 3.8초 보장).
/// 길게 잡아 궤적이 충분히 펼쳐지고, 막판 원근 축소가 '머얼리' 사라지게 한다.
const Duration _kFlyDuration = Duration(milliseconds: 4000);

// (텍스트 종이 → 다트 글리프 크로스페이드는 접기 막바지 ~80ms ≈ wings 구간의
//  마지막 ~16%를 progress 비율로 구동한다 — _FoldingPaper.glyphT 참조.)

// ── 인플레이스 완료 타임라인(다트 소멸=0 기준) — 태우기와 톤 일치 ──────────
/// 다트가 사라진 뒤 멘트가 뜨기 전 여운(비행기는 잔향 없으니 짧게).
const Duration _kMessageDelay = Duration(milliseconds: 900);

/// 멘트 페이드인(opacity 0→1).
const Duration _kMessageFade = Duration(milliseconds: 1400);

/// 멘트 뜬 뒤 '처음으로' 버튼까지(= 900 + 1300).
const Duration _kButtonDelay = Duration(milliseconds: 2200);

/// 버튼 페이드인.
const Duration _kButtonFade = Duration(milliseconds: 800);

// ── 접기 크리스 햅틱 발사 지점(진행도) ──────────────────────────────────────
// 각 구간 끝 직전(손을 떼는 호흡). light·light·medium — 마지막 날개접기가 단단.
const double _kCreaseCenter = 0.30;
const double _kCreaseNose = 0.63;
const double _kCreaseWings = 0.97;

// ── 종이 / 다트 표시 크기 ──────────────────────────────────────────────────
const double _kPaperW = 240;
const double _kPaperH = 320;
const double _kGlyphSize = 200; // 접힌 다트 표시 크기(종이와 시각 균형).

// ── 던지기 물리 상수 ───────────────────────────────────────────────────────
/// 약투 무시 임계(px/s). 이하면 제자리(되돌림).
const double _kThrowMin = 300;
/// 세기 정규화 분모(maxSpeed - min ≈ 2300).
const double _kSpeedSpan = 2300;

/// RIT-09 종이비행기. 종이를 3단계로 실제 접어(크리스 햅틱) 다트를 만든 뒤,
/// 손가락으로 던진 방향·세기로 날려 보낸다. 비행 후 같은 화면에 인플레이스 완료.
class PaperPlaneRitualScreen extends StatefulWidget {
  const PaperPlaneRitualScreen({super.key});

  @override
  State<PaperPlaneRitualScreen> createState() => _PaperPlaneRitualScreenState();
}

class _PaperPlaneRitualScreenState extends State<PaperPlaneRitualScreen>
    with TickerProviderStateMixin {
  _Phase _phase = _Phase.idle;

  // 접기 컨트롤러(0→1, 3구간 매핑). bounded.
  late final AnimationController _fold;
  // 비행 컨트롤러(0→1). bounded.
  late final AnimationController _fly;
  // 구름 흩어짐 컨트롤러(done 진입 후 0→1, 잔향 구름이 옅어지며 흩어짐). bounded.
  late final AnimationController _cloudFade;
  // 구름 퍼프 결정적 시드(재현성).
  static const int _cloudSeed = 20260601;
  // 천천히 멀어지는 느낌(easeInOutSine): 부드럽게 출발해 일정히 나아가며
  //  후반에 급정거 없이 먼 하늘로 빠져나간다(easeOutCubic처럼 막판 정지하지 않음).
  late final Animation<double> _flyCurve =
      CurvedAnimation(parent: _fly, curve: Curves.easeInOutSine);

  // 접기 크리스 햅틱 fired-set 가드(playTimeline 대신 직접 fire).
  final Set<int> _firedCrease = {};

  // 던지기 결과.
  Offset _flyDir = const Offset(1, -1); // 진행 방향 단위벡터.
  double _flySpeed = 0; // 0~1 → 비행 거리.
  double _flyAngle = 0; // 다트 코를 진행 방향으로 정렬한 각.

  // 비행 중 연속 '진공' 햅틱 핸들(던지는 순간 시작 → 완료/dispose에서 stop).
  // sensory-haptics가 haptics.dart에 추가하는 startFlightHum()/FlightHandle 사용.
  FlightHandle? _flightHandle;

  // 인플레이스 완료 토글.
  bool _showMessage = false;
  bool _showButton = false;

  @override
  void initState() {
    super.initState();
    _fold = AnimationController(vsync: this, duration: _kFoldDuration)
      ..addListener(_onFoldTick)
      ..addStatusListener(_onFoldStatus);
    _fly = AnimationController(vsync: this, duration: _kFlyDuration)
      ..addStatusListener(_onFlyStatus);
    // 잔향 구름 흩어짐: done 진입 후 천천히(완료 멘트와 겹치지 않게 은은히).
    _cloudFade =
        AnimationController(vsync: this, duration: const Duration(seconds: 3));
  }

  // ── 접기: 크리스 햅틱(직접 fire, fired-set 가드) ──────────────────────────
  void _onFoldTick() {
    final t = _fold.value;
    // ① center crease(light) ② nose(light) ③ wings(medium, 가장 단단).
    if (t >= _kCreaseCenter && _firedCrease.add(0)) {
      Haptics.instance.fire(HapticLevel.light);
    }
    if (t >= _kCreaseNose && _firedCrease.add(1)) {
      Haptics.instance.fire(HapticLevel.light);
    }
    if (t >= _kCreaseWings && _firedCrease.add(2)) {
      Haptics.instance.fire(HapticLevel.medium, throttle: false);
    }
    setState(() {}); // 접기 변형 갱신.
  }

  void _onFoldStatus(AnimationStatus s) {
    if (s == AnimationStatus.completed && _phase == _Phase.folding) {
      setState(() => _phase = _Phase.folded);
    }
  }

  void _onFlyStatus(AnimationStatus s) {
    if (s == AnimationStatus.completed && _phase == _Phase.flying) {
      _complete();
    }
  }

  // ── 접기 시작(버튼/탭) → 자동 3단계 ──────────────────────────────────────
  void _startFold() {
    if (_phase != _Phase.idle) return;
    _firedCrease.clear();
    setState(() => _phase = _Phase.folding); // float:false 전환(접기와 충돌 방지).
    _fold.forward(from: 0);
  }

  // ── 던지기(throw) — onPanEnd ──────────────────────────────────────────────
  void _throw(DragEndDetails d) {
    if (_phase != _Phase.folded) return;
    final v = d.velocity.pixelsPerSecond;
    final dist = v.distance;
    if (dist == 0) return; // NaN 방지: 정규화 생략하고 즉시 return.
    if (dist < _kThrowMin) return; // 약투 무시(제자리, 상태 유지).
    _flyDir = v / dist;
    _flySpeed = ((dist - _kThrowMin) / _kSpeedSpan).clamp(0.0, 1.0);
    // 글리프 코는 -y이므로 진행 방향 정렬 보정각 = atan2 + π/2.
    _flyAngle = atan2(_flyDir.dy, _flyDir.dx) + pi / 2;
    Haptics.instance.impactBySpeed(dist); // 세게 던질수록 강하게.
    // 발사 직후: 비행 동안 내내 도는 '진공' 연속 햅틱 시작(완료에 stop).
    _flightHandle = Haptics.instance.startFlightHum();
    setState(() => _phase = _Phase.flying);
    _fly.forward(from: 0);
  }

  // ── 비행 완료 → 인플레이스 완료 시퀀스(태우기 패턴) ───────────────────────
  void _complete() {
    if (_phase == _Phase.done || !mounted) return;
    // 착지(먼 점이 되어 사라짐) — 비행 연속 햅틱 정지.
    _flightHandle?.stop();
    _flightHandle = null;
    setState(() => _phase = _Phase.done);
    // 비행기는 먼 하늘로 사라짐 — 경로에 피어난 잔향 구름을 천천히 흩어지게.
    _cloudFade.forward(from: 0);

    Future.delayed(_kMessageDelay, () {
      if (!mounted) return;
      // 멘트 페이드인 시작 순간 부드러운 완료 햅틱 1회(CompleteScreen 톤).
      Haptics.instance.fire(HapticLevel.success, throttle: false);
      setState(() => _showMessage = true);
    });
    Future.delayed(_kButtonDelay, () {
      if (!mounted) return;
      setState(() => _showButton = true);
    });
  }

  // ── '처음으로': 세션 리셋 + 홈 복귀(태우기·CompleteScreen과 동일) ──
  void _backToHome() {
    SessionScope.of(context).reset();
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  void dispose() {
    // 비행 도중 화면 이탈 시 연속 햅틱 누수 방지(stop은 idempotent).
    _flightHandle?.stop();
    _flightHandle = null;
    _fold
      ..removeListener(_onFoldTick)
      ..removeStatusListener(_onFoldStatus)
      ..dispose();
    _fly
      ..removeStatusListener(_onFlyStatus)
      ..dispose();
    _cloudFade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = SessionScope.of(context).text;
    final folding = _phase == _Phase.folding;
    // idle/folding엔 종이를 탭하면 접기 시작(버튼 외 추가 트리거).
    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Stack(
            children: [
              // ── 중앙 오브제(접기 종이 ↔ 다트) ──
              Center(
                child: GestureDetector(
                  onTap: _phase == _Phase.idle ? _startFold : null,
                  onPanEnd: _phase == _Phase.folded ? _throw : null,
                  behavior: HitTestBehavior.opaque,
                  child: AnimatedBuilder(
                    animation: Listenable.merge([_fold, _flyCurve]),
                    builder: (context, _) => _buildObject(context, text),
                  ),
                ),
              ),

              // ── 구름 레이어(비행 경로 따라 그림책 뭉게구름이 점점이 피어남) ──
              // 비행기를 가리지 않고 경로 주변에 피어나며, 비행기는 그 사이를
              // 지나 멀리 후퇴해 작은 점이 되어 사라진다. flying/done에만 활성.
              if (_phase == _Phase.flying || _phase == _Phase.done)
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedBuilder(
                      animation: Listenable.merge([_flyCurve, _cloudFade]),
                      builder: (context, _) {
                        final size = MediaQuery.of(context).size;
                        return CustomPaint(
                          painter: _CloudFieldPainter(
                            flyT: _flyCurve.value,
                            center: Offset(size.width / 2, size.height / 2),
                            screenSize: size,
                            dir: _flyDir,
                            flySpeed: _flySpeed,
                            dissipate: _cloudFade.value, // done 후 흩어짐(0→1).
                            seed: _cloudSeed,
                          ),
                        );
                      },
                    ),
                  ),
                ),

              // ── 하단 안내/버튼 ──
              Positioned(
                left: 0,
                right: 0,
                bottom: 44,
                child: IgnorePointer(
                  ignoring: _phase != _Phase.idle,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 300),
                    opacity: _phase == _Phase.idle
                        ? 1.0
                        : (_phase == _Phase.folded ? 1.0 : 0.0),
                    child: Center(
                      child: _phase == _Phase.folded
                          ? const Text(
                              '손가락으로 휙 던져 날려 보내요',
                              style: TextStyle(color: Colors.white60),
                            )
                          : FilledButton.icon(
                              onPressed: folding ? null : _startFold,
                              icon: const PaperPlaneGlyph(size: 18),
                              label: const Text('비행기로 접어요'),
                              style: FilledButton.styleFrom(
                                backgroundColor: AppColors.ballGlow,
                              ),
                            ),
                    ),
                  ),
                ),
              ),

              // ── 완료 멘트(인플레이스 페이드인) ──
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

              // ── '처음으로' 버튼(멘트 뒤 페이드인) ──
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
          ),
        ),
      ),
    );
  }

  // ── 중앙 오브제 빌더: 접기 변형 / 비행 변환 / 크로스페이드 ──────────────────
  Widget _buildObject(BuildContext context, String text) {
    // 비행 변환(flying/done): 던진 방향으로 부드러운 곡선 궤적을 그리며 멀어지고,
    //  원근으로 작아져 먼 점이 되어 사라진다(중반 소멸 금지 — 또렷이 날아간다).
    if (_phase == _Phase.flying || _phase == _Phase.done) {
      final t = _flyCurve.value;
      final size = MediaQuery.of(context).size;
      final offset = _flightOffset(size, _flyDir, _flySpeed, t);
      // 원근 후퇴: 1→0.10까지, 후반 가속 축소(t²의 가중)로 '먼 하늘로' 빨려든다.
      //  ease가 후반부에 더 깊이 줄어 멀어질수록 급격히 작아지는 원근감.
      final shrink = t * (0.55 + t * 0.45); // 0→1, 후반 가속.
      final scale = (1.0 - shrink * 0.90).clamp(0.10, 1.0);
      // opacity는 막판(t>0.85)에만 서서히 0으로 — 중반엔 또렷이 보이며 날아간다.
      final planeOpacity = (1.0 - ((t - 0.85) / 0.15).clamp(0.0, 1.0))
          .clamp(0.0, 1.0);
      return Transform.translate(
        offset: offset,
        child: Transform.rotate(
          angle: _flyAngle,
          child: Transform.scale(
            scale: scale,
            child: Opacity(
              opacity: planeOpacity,
              child: const PaperPlaneGlyph(size: _kGlyphSize, shadow: true),
            ),
          ),
        ),
      );
    }

    // idle: 흩날리는 텍스트 종이.
    if (_phase == _Phase.idle) {
      return const _SizedPaper(float: true);
    }

    // folded: 정지 다트.
    if (_phase == _Phase.folded) {
      return const PaperPlaneGlyph(size: _kGlyphSize, shadow: true);
    }

    // folding: 3단계 접기 모핑 + 막바지 글리프 크로스페이드.
    return _FoldingPaper(progress: _fold.value, text: text);
  }
}

/// 접기 전/후 공통 종이 박스(고정 크기). float만 토글.
class _SizedPaper extends StatelessWidget {
  const _SizedPaper({required this.float});
  final bool float;

  @override
  Widget build(BuildContext context) {
    final text = SessionScope.of(context).text;
    return PaperCard(
      text: text,
      width: _kPaperW,
      height: _kPaperH,
      float: float,
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// 접기 모핑 위젯: 단일 progress(0→1)를 3구간으로 나눠 Matrix4 perspective로
// 실제 종이접기를 근사한다.
//   ① center crease (0.00–0.33): 오른쪽 절반 플랩이 안쪽으로 접혀 넘어가는
//      rotateY 3D 회전(perspective). 접힌 면 음영↑ + 중앙 크리스 라인.
//   ② nose (0.33–0.66): 상단 양 모서리가 중앙으로 모여 삼각 코.
//   ③ wings (0.66–1.00): 양 날개가 동체 기준 아래로 꺾여 다트. 막바지에
//      텍스트 종이 → PaperPlaneGlyph 크로스페이드(~80ms).
// ════════════════════════════════════════════════════════════════════════
class _FoldingPaper extends StatelessWidget {
  const _FoldingPaper({required this.progress, required this.text});

  final double progress; // 0→1.
  final String text;

  // perspective 깊이(원근). 작을수록 약한 원근.
  static const double _kPerspective = 0.0014;

  @override
  Widget build(BuildContext context) {
    // 구간 정규화(각 구간 내 0→1, easeInOut으로 "탁" 눌리는 느낌).
    final c1 = Curves.easeInOut.transform((progress / 0.33).clamp(0.0, 1.0));
    final c2 = Curves.easeInOut
        .transform(((progress - 0.33) / 0.33).clamp(0.0, 1.0));
    final c3 = Curves.easeInOut
        .transform(((progress - 0.66) / 0.34).clamp(0.0, 1.0));

    // 막바지(③ 후반)에 다트 글리프로 크로스페이드.
    // 80ms ≈ wings 구간(0.66–1.00, 510ms)의 마지막 ~16%.
    final glyphT = ((progress - 0.84) / 0.16).clamp(0.0, 1.0);

    return SizedBox(
      width: _kPaperW,
      height: _kPaperH,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 접히는 종이(글리프가 다 뜨면 페이드아웃).
          Opacity(
            opacity: (1 - glyphT).clamp(0.0, 1.0),
            child: _buildFoldingPaper(c1, c2, c3),
          ),
          // 완성 다트(막바지 크로스페이드 등장).
          if (glyphT > 0)
            Opacity(
              opacity: glyphT,
              child: const PaperPlaneGlyph(size: _kGlyphSize, shadow: true),
            ),
        ],
      ),
    );
  }

  Widget _buildFoldingPaper(double c1, double c2, double c3) {
    // ③ wings: 동체 폭이 좁아지며 세로로 길쭉(다트 실루엣 수렴) + 살짝 위로.
    final wingNarrow = 1.0 - c3 * 0.55; // 가로 수축.
    final wingTall = 1.0 + c3 * 0.10; // 세로 신장.

    // ② nose: 상단이 삼각으로 모이며 전체가 살짝 위로 솟는 느낌(원근 tilt).
    final noseTilt = c2 * 0.18; // rotateX 근사(상단이 멀어짐).

    // ★ 중앙 보정: ① center-crease의 오른쪽 플랩이 rotateY(c1·π)로 안쪽으로
    //   접히면, 보이는 종이의 시각 무게중심이 hinge(중앙)쪽=왼쪽으로 쏠려
    //   "접기가 중앙에서 벗어나" 보인다. 두 절반의 합성 centroid가 다시 중앙(0)에
    //   오도록 오른쪽으로 dx만큼 보정 translate.
    //   centroid_x = (W/8)(cos(c1·π) − 1) ≤ 0  →  보정 dx = −centroid_x.
    final creaseDx = (_kPaperW / 8) * (1 - cos(c1 * pi));

    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..setEntry(3, 2, _kPerspective)
        ..rotateX(noseTilt)
        ..scaleByDouble(wingNarrow, wingTall, 1, 1)
        // 마지막 op = 자식 좌표에 먼저 적용 → 종이 로컬 프레임에서 수평 보정.
        ..translateByDouble(creaseDx, 0, 0, 1),
      child: SizedBox(
        width: _kPaperW,
        height: _kPaperH,
        child: Stack(
          children: [
            // ── ① 왼쪽 절반(고정 면) ──
            Align(
              alignment: Alignment.centerLeft,
              child: _half(left: true, foldT: c1, noseT: c2),
            ),
            // ── ① 오른쪽 절반(안쪽으로 접혀 넘어가는 플랩) ──
            Align(
              alignment: Alignment.centerLeft,
              child: Transform(
                alignment: Alignment.centerLeft, // 중앙 크리스를 경첩으로.
                transform: Matrix4.identity()
                  ..setEntry(3, 2, _kPerspective)
                  // rotateY 0→π 근사(안쪽으로 접혀 넘어감). c1로 구동.
                  ..rotateY(c1 * pi),
                child: _half(
                  left: false,
                  foldT: c1,
                  noseT: c2,
                  // 접혀 넘어가는 면은 점점 음영↑(뒷면 그늘).
                  shade: c1,
                ),
              ),
            ),
            // ── 중앙 크리스 라인(1px, ink 20%) ──
            Positioned(
              left: _kPaperW / 2 - 0.5,
              top: 0,
              bottom: 0,
              child: Opacity(
                opacity: (c1 * 0.8).clamp(0.0, 1.0),
                child: Container(
                  width: 1,
                  color: const Color(0xFF2B2B33).withValues(alpha: 0.20),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 종이 절반(좌/우). foldT=center crease 진행, noseT=상단 삼각 코 진행.
  Widget _half({
    required bool left,
    required double foldT,
    required double noseT,
    double shade = 0,
  }) {
    return SizedBox(
      width: _kPaperW / 2,
      height: _kPaperH,
      child: ClipRect(
        child: Stack(
          children: [
            // 절반 종이 본체(텍스트 일부). 텍스트는 코접힘 단계에서 숨겨 깔끔히.
            Positioned(
              // 두 절반을 합쳐 온전한 종이로 보이도록 텍스트 패딩 정렬.
              left: left ? 0 : -_kPaperW / 2,
              top: 0,
              width: _kPaperW,
              height: _kPaperH,
              child: Opacity(
                opacity: (1 - noseT).clamp(0.0, 1.0) * 0.0 + 1.0,
                child: _SizedPaperFace(
                  text: noseT > 0.05 ? '' : text,
                ),
              ),
            ),
            // ② nose 삼각면 음영: 상단 모서리(좌/우)가 중앙으로 접힌 삼각 그늘.
            if (noseT > 0)
              Positioned.fill(
                child: CustomPaint(
                  painter: _NoseShadePainter(t: noseT, left: left),
                ),
              ),
            // ① 접힌 면 그늘(오른쪽 플랩이 넘어가며 어두워짐).
            if (shade > 0)
              Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(
                    color: const Color(0xFF2B2B33)
                        .withValues(alpha: 0.22 * shade),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 접기용 종이 면(그림자·float 없이 순수 면 — Matrix4 변형 대상).
class _SizedPaperFace extends StatelessWidget {
  const _SizedPaperFace({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return PaperCard(
      text: text,
      width: _kPaperW,
      height: _kPaperH,
      shadow: false,
      float: false,
    );
  }
}

/// ② nose 단계: 상단 모서리가 중앙으로 접힌 삼각 코의 음영(paperShadow).
/// 좌/우 절반에 각각 안쪽 위 모서리에서 내려오는 삼각형 그늘을 그린다.
class _NoseShadePainter extends CustomPainter {
  _NoseShadePainter({required this.t, required this.left});

  final double t; // 0→1 nose 진행.
  final bool left;

  static const Color _paperShadow = Color(0xFFE7DEC9);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    // 삼각 코: 위쪽 바깥 모서리 → 중앙선(안쪽)으로 접힌 삼각면.
    // left 절반은 오른쪽(안쪽=중앙)이 keel, right 절반은 왼쪽이 keel.
    final innerX = left ? w : 0.0; // 중앙선 쪽.
    final outerX = left ? 0.0 : w; // 바깥쪽.
    final apexY = size.height * (0.45 * t); // 접힌 삼각의 아래 꼭짓점(t로 깊어짐).

    final path = Path()
      ..moveTo(outerX, 0)
      ..lineTo(innerX, 0)
      ..lineTo(innerX, apexY)
      ..close();

    canvas.drawPath(
      path,
      Paint()..color = _paperShadow.withValues(alpha: 0.85 * t),
    );
    // 접힌 모서리 선(살짝 진하게).
    canvas.drawLine(
      Offset(outerX, 0),
      Offset(innerX, apexY),
      Paint()
        ..color = const Color(0xFF2B2B33).withValues(alpha: 0.12 * t)
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _NoseShadePainter old) =>
      old.t != t || old.left != left;
}

// ════════════════════════════════════════════════════════════════════════
// 비행 경로 공식(단일 출처): 비행기의 Center(화면중앙) 기준 오프셋.
//   - 비행기 Transform(_buildObject)과 구름 레이어(_CloudFieldPainter)가
//     동일 공식을 호출 → 화면 좌표(중앙+offset)가 두 레이어에서 일치.
//   - dir: 진행 단위벡터, speed: 0~1(거리), t: 비행 진행(곡선 적용 후).
// ════════════════════════════════════════════════════════════════════════
Offset _flightOffset(Size size, Offset dir, double speed, double t) {
  // 거리 상향: 화면을 가로질러 '멀리'(화면 밖) 후퇴 — 먼 점이 되어 사라지게.
  final dist = size.longestSide * (1.0 + speed * 0.8);
  final base = dir * dist * t;
  // 고도감: 던진 직후 살짝 위로 솟았다(상승) 멀리 날아가는 완만한 포물선.
  //  -sin(t·π)은 중반에 최고로 솟았다 가라앉는 대칭형이라 '솟구쳐 멀어짐'이
  //  덜 보인다. 대신 초반에 빨리 솟고(상승) 천천히 잦아드는 비대칭 lift를 쓴다.
  //  진행 방향에 수직(위쪽 성분이 큰)으로 살짝 띄워 부드러운 S 곡선 궤적을 만든다.
  final lift = -sin(t * pi * 0.82) * (70 + speed * 30) * (1 - t * 0.35);
  // 가로 일렁임(고도와 합쳐져 완만한 S): 느린 비행 동안 부드럽게, 말미로 잦아듦.
  final sway = sin(t * pi * 1.3) * 26 * (1 - t);
  // perp: 진행 방향에 수직(화면상 '위쪽' 쪽으로 lift를 얹기 위한 기준).
  final perp = Offset(-dir.dy, dir.dx);
  return base + Offset(sway, lift) + perp * (lift * 0.18);
}

// ════════════════════════════════════════════════════════════════════════
// 구름 레이어: 비행 경로를 따라 '그림책 뭉게구름(cumulus)'이 점점이 피어난다.
//   - 한 덩이 = 여러 둥근 lobe(원호)가 겹친 뭉게구름 실루엣(아래 평평, 위는
//     둥근 봉우리 여러 개) + 부드러운 흰 채움 + 윗면 하이라이트/아랫면 옅은 그늘.
//     외곽은 약한 blur로 soft하되 형태가 구름으로 읽힌다.
//   - 비행기가 궤적을 따라 지나가며 경로 주변에 피어나 천천히 커지고 떠다니다
//     옅어진다. 멀리(후반 emit)의 구름은 작게 그려 원근감. 비행기를 가리지 않고
//     (occlusion 뱅크 제거) 그 사이를 지나 멀리 간다.
//   - 결정적: Random(seed)로 lobe 파라미터 고정(재현성·프레임 점프 0).
//   - 색: 흰색~연한 라벤더(어둡지 않게), painter 로컬 const(테마 토큰 추가 X).
//   - dissipate(0→1, done 후): 잔향 구름이 옅어지며 살짝 위로 흩어짐.
// ════════════════════════════════════════════════════════════════════════
class _CloudFieldPainter extends CustomPainter {
  _CloudFieldPainter({
    required this.flyT,
    required this.center,
    required this.screenSize,
    required this.dir,
    required this.flySpeed,
    required this.dissipate,
    required this.seed,
  });

  final double flyT; // 비행 진행(곡선 후).
  final Offset center; // 화면 중앙.
  final Size screenSize;
  final Offset dir; // 진행 단위벡터.
  final double flySpeed; // 0~1.
  final double dissipate; // done 후 흩어짐 0→1.
  final int seed;

  // 경로 따라 피어나는 뭉게구름 덩이 수(occlusion 뱅크 제거 — 가리지 않음).
  static const int _trailCount = 11;

  // 구름 톤(흰색~연한 라벤더). 어둡지 않게, 은은히.
  static const Color _cloudWhite = Color(0xFFFFFFFF);
  static const Color _cloudLavender = Color(0xFFEDE7FB);
  // 그림책 명암: 윗면 하이라이트(살짝 더 흰)·아랫면 옅은 라벤더 그늘.
  static const Color _cloudHighlight = Color(0xFFFFFFFF);
  static const Color _cloudShade = Color(0xFFD8CEF0);

  // 경로 위 한 점의 화면 좌표(비행기와 동일 공식).
  Offset _pathPoint(double t) =>
      center + _flightOffset(screenSize, dir, flySpeed, t);

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = Random(seed);
    // 진행 방향에 수직(lateral) 단위벡터 — 구름 측면 산포에 사용.
    final perp = Offset(-dir.dy, dir.dx);

    // ── 경로를 따라 점점이 피어나는 그림책 뭉게구름 ──
    // 경로 t∈[0.03, 0.86]에 결정적으로 분산 emit, 나이 들며 커지고 떠다니다 옅어짐.
    for (var i = 0; i < _trailCount; i++) {
      // 모든 파라미터를 먼저 결정적으로 소비(분기와 무관하게 RNG 스트림 고정 →
      // flyT 증가에 따른 구름 위치 점프 방지).
      final jitterT = rnd.nextDouble();
      final lateral = (rnd.nextDouble() - 0.5) * 110; // 경로 양옆 산포.
      final along = (rnd.nextDouble() - 0.5) * 44; // 경로 따라 미세 산포.
      final wobbleR = 0.85 + rnd.nextDouble() * 0.5; // 크기 변주.
      final tintPick = rnd.nextDouble();
      final lobeSeed = rnd.nextInt(1 << 30); // 이 덩이의 lobe 배치 시드(고정).

      // 결정적 emit 진행도(경로 전반에 고르게).
      final emitT = 0.03 + 0.83 * (i + jitterT * 0.6) / _trailCount;
      if (flyT < emitT) continue; // 아직 그 지점 미도달 — 그리지 않음.

      // 나이(0→1): emit 직후 0 → 비행 끝/그 이후로 갈수록 1.
      final age = ((flyT - emitT) / (1.0 - emitT)).clamp(0.0, 1.0);
      // 피어남: 작게 시작→천천히 커짐(easeOut).
      final grow = Curves.easeOut.transform(age);

      // 원근: 멀리(후반 emit) 피어난 구름일수록 작게(비행기 후퇴와 동조).
      final persp = 1.0 - emitT * 0.55; // emit 0→1 : 1.0→0.45 스케일.
      final radius = (30 + grow * 46) * wobbleR * persp;

      // 떠오름: 나이 들수록 살짝 위로 부유.
      final pos = _pathPoint(emitT) +
          perp * lateral * persp +
          dir * along +
          Offset(0, -grow * 24);

      // 불투명도: 등장(빠르게 0→peak) 후 서서히 옅어짐 + done 흩어짐.
      final appear = (age / 0.22).clamp(0.0, 1.0);
      final fade = (1.0 - (age - 0.45).clamp(0.0, 1.0) / 0.55);
      final opacity =
          (0.66 * appear * fade * (1.0 - dissipate)).clamp(0.0, 1.0);
      if (opacity <= 0.01) continue;

      // done 흩어짐: 살짝 더 위로 떠오르며 퍼짐.
      final driftPos = pos + Offset(0, -dissipate * 30);
      _cumulus(
        canvas,
        driftPos,
        radius * (1 + dissipate * 0.22),
        opacity,
        tintPick < 0.5 ? _cloudLavender : _cloudWhite,
        lobeSeed,
      );
    }
  }

  // ── 그림책 뭉게구름 한 덩이 ──
  // 아래는 평평, 위는 둥근 봉우리 여러 개. 여러 lobe(원호)를 겹쳐 실루엣을
  // 부드러운 흰색으로 채우고, 아랫면에 옅은 라벤더 그늘 + 윗면 하이라이트로
  // '그림책 구름'처럼 입체를 준다. 외곽은 약한 blur로 soft(형태는 유지).
  void _cumulus(Canvas canvas, Offset c, double r, double opacity, Color tint,
      int lobeSeed) {
    final rnd = Random(lobeSeed);
    // lobe(봉우리) 개수: 3~4개. 아래는 평평(밑변), 위로 봉우리들이 솟음.
    final lobeCount = 3 + (rnd.nextInt(2)); // 3 또는 4.
    final baseY = c.dy + r * 0.42; // 평평한 밑면 y(살짝 아래).

    // lobe 중심들: 가로로 펼쳐 배치, 가운데가 가장 높고 양끝이 낮은 봉우리.
    final lobes = <(Offset, double)>[]; // (center, radius)
    for (var i = 0; i < lobeCount; i++) {
      // -1..1 가로 위치(균등 + 약간의 지터).
      final u = lobeCount == 1
          ? 0.0
          : (i / (lobeCount - 1)) * 2 - 1 + (rnd.nextDouble() - 0.5) * 0.18;
      // 가운데 봉우리가 크고 높게, 양끝은 작고 낮게(뭉게구름 봉우리감).
      final centerness = 1 - u.abs(); // 0(끝)~1(가운데).
      final lobeR = r * (0.55 + centerness * 0.42 + rnd.nextDouble() * 0.08);
      final cx = c.dx + u * r * 0.92;
      // 봉우리 꼭대기가 밑면 위로 솟도록: 큰 lobe가 더 높이.
      final cy = baseY - lobeR * (0.78 + centerness * 0.30);
      lobes.add((Offset(cx, cy), lobeR));
    }

    // 실루엣 path: 각 lobe 원 + 밑변을 평평하게 자르는 사각형 결합(union).
    var silhouette = Path();
    for (final (lc, lr) in lobes) {
      silhouette = Path.combine(
        PathOperation.union,
        silhouette,
        Path()..addOval(Rect.fromCircle(center: lc, radius: lr)),
      );
    }
    // 밑면 아래를 잘라 평평한 바닥(cumulus 특징).
    final clip = Path()
      ..addRect(Rect.fromLTRB(
          c.dx - r * 2, c.dy - r * 2, c.dx + r * 2, baseY));
    final body = Path.combine(PathOperation.intersect, silhouette, clip);

    // soft 외곽: 약한 blur(형태가 구름으로 읽히도록 r에 비례해 작게).
    final blur = MaskFilter.blur(BlurStyle.normal, r * 0.12);

    // ① 아랫면 옅은 그늘(밑동을 라벤더로 깔아 입체) — 본체 아래쪽.
    canvas.save();
    canvas.clipPath(body);
    final shadeRect = Rect.fromLTRB(
        c.dx - r * 1.4, c.dy - r * 0.2, c.dx + r * 1.4, baseY + r * 0.2);
    canvas.drawRect(
      shadeRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            _cloudShade.withValues(alpha: 0.0),
            _cloudShade.withValues(alpha: opacity * 0.55),
          ],
        ).createShader(shadeRect),
    );
    canvas.restore();

    // ② 본체 채움: 부드러운 흰(틴트) — blur로 가장자리 soft.
    canvas.drawPath(
      body,
      Paint()
        ..maskFilter = blur
        ..color = tint.withValues(alpha: opacity),
    );

    // ③ 윗면 하이라이트: 각 봉우리 위쪽에 작은 흰 하이라이트(빛이 위에서).
    canvas.save();
    canvas.clipPath(body);
    for (final (lc, lr) in lobes) {
      final hc = lc + Offset(-lr * 0.18, -lr * 0.30);
      final hRect = Rect.fromCircle(center: hc, radius: lr * 0.7);
      canvas.drawCircle(
        hc,
        lr * 0.7,
        Paint()
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, lr * 0.22)
          ..shader = RadialGradient(
            colors: [
              _cloudHighlight.withValues(alpha: opacity * 0.5),
              _cloudHighlight.withValues(alpha: 0.0),
            ],
          ).createShader(hRect),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CloudFieldPainter old) =>
      old.flyT != flyT ||
      old.dissipate != dissipate ||
      old.center != center ||
      old.dir != dir ||
      old.flySpeed != flySpeed;
}
