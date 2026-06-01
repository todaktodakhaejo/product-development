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

/// 비행 글라이드 길이(천천히 화면을 가로질러 구름 속으로 — 최소 3초 보장).
const Duration _kFlyDuration = Duration(milliseconds: 3200);

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
  // 3.2초 내내 움직임이 느껴지도록 easeInOutCubic(easeOutCubic은 초반에 거의
  //  다 가버려 후반 2초가 멈춰 보임). 부드럽게 출발→가속→감속하며 구름 속으로.
  late final Animation<double> _flyCurve =
      CurvedAnimation(parent: _fly, curve: Curves.easeInOutCubic);

  // 접기 크리스 햅틱 fired-set 가드(playTimeline 대신 직접 fire).
  final Set<int> _firedCrease = {};

  // 던지기 결과.
  Offset _flyDir = const Offset(1, -1); // 진행 방향 단위벡터.
  double _flySpeed = 0; // 0~1 → 비행 거리.
  double _flyAngle = 0; // 다트 코를 진행 방향으로 정렬한 각.

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
    setState(() => _phase = _Phase.flying);
    _fly.forward(from: 0);
  }

  // ── 비행 완료 → 인플레이스 완료 시퀀스(태우기 패턴) ───────────────────────
  void _complete() {
    if (_phase == _Phase.done || !mounted) return;
    setState(() => _phase = _Phase.done);
    // 비행기는 이미 구름에 휩싸여 사라짐 — 남은 잔향 구름을 천천히 흩어지게.
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

              // ── 구름 레이어(비행 경로 따라 피어남 + 막바지 덮는 구름 뱅크) ──
              // 비행기 Center 위에 그려져, 막바지 짙은 뱅크가 비행기를 가린다.
              // flying/done(구름 소멸 잔향)에만 활성.
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
    // 비행 변환(flying/done): 던진 방향·세기 글라이드 + 포물선 lift + wobble.
    if (_phase == _Phase.flying || _phase == _Phase.done) {
      final t = _flyCurve.value;
      final size = MediaQuery.of(context).size;
      final offset = _flightOffset(size, _flyDir, _flySpeed, t);
      // 구름 진입과 동조한 페이드: 후반(t≥0.55)부터 덮는 구름 밀도에 맞춰 빠르게
      // 사라져 '구름에 휩싸여' 소멸(빈 하늘 축소소멸 아님).
      final cloudVeil = ((t - 0.55) / 0.32).clamp(0.0, 1.0);
      final planeOpacity =
          ((1 - t) * (1 - cloudVeil * 0.92)).clamp(0.0, 1.0);
      return Transform.translate(
        offset: offset,
        child: Transform.rotate(
          angle: _flyAngle,
          child: Transform.scale(
            scale: 1 - t * 0.7,
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
  final dist = size.longestSide * (0.7 + speed * 0.7);
  final base = dir * dist * t;
  // 살짝 떠올랐다 가라앉는 lift(3초에 맞춰 진폭 유지) + 말미로 잦아드는 wobble.
  // 주기를 살짝 늘려(×1.6) 느린 비행 동안 좌우로 부드럽게 일렁이게.
  final wobble = Offset(
    sin(t * pi * 1.6) * 22 * (1 - t),
    -sin(t * pi) * 40,
  );
  return base + wobble;
}

// ════════════════════════════════════════════════════════════════════════
// 구름 레이어: 비행 경로를 따라 부드러운 흰 퍼프가 피어나고(trailing),
// 막바지(t≳0.55)엔 비행기 진행 위치 살짝 앞에 더 크고 짙은 '덮는 구름 뱅크'가
// 모여 비행기를 감싸 가린다. 비행기 Center 위에 그려져 occlusion 성립.
//   - 결정적: Random(seed)로 퍼프 파라미터 고정(재현성).
//   - 색: 흰색~연한 라벤더(어둡지 않게), painter 로컬 const(테마 토큰 추가 X).
//   - dissipate(0→1, done 후): 잔향 퍼프가 옅어지며 살짝 흩어짐.
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

  // 퍼프 개수: trailing(경로 따라) + 덮는 구름 뱅크.
  static const int _trailCount = 10;
  static const int _bankCount = 9;

  // 구름 톤(흰색~연한 라벤더). 어둡지 않게, 은은히.
  static const Color _cloudWhite = Color(0xFFFFFFFF);
  static const Color _cloudLavender = Color(0xFFEDE7FB);

  // 경로 위 한 점의 화면 좌표(비행기와 동일 공식).
  Offset _pathPoint(double t) =>
      center + _flightOffset(screenSize, dir, flySpeed, t);

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = Random(seed);
    // 진행 방향에 수직(lateral) 단위벡터 — 퍼프 측면 산포에 사용.
    final perp = Offset(-dir.dy, dir.dx);

    // ── ① trailing 퍼프: 경로 t∈[0.03, 0.82]에 분산 emit, 나이 들며 커지고 옅어짐 ──
    for (var i = 0; i < _trailCount; i++) {
      // 모든 파라미터를 먼저 결정적으로 소비(분기와 무관하게 RNG 스트림 고정 →
      // flyT 증가에 따른 퍼프 위치 점프 방지).
      final jitterT = rnd.nextDouble();
      final lateral = (rnd.nextDouble() - 0.5) * 90; // 경로 양옆 산포.
      final along = (rnd.nextDouble() - 0.5) * 40; // 경로 따라 미세 산포.
      final wobbleR = 0.85 + rnd.nextDouble() * 0.5; // 크기 변주.
      final tintPick = rnd.nextDouble();

      // 결정적 emit 진행도.
      final emitT = 0.03 + 0.79 * (i + jitterT * 0.6) / _trailCount;
      if (flyT < emitT) continue; // 아직 그 지점 미도달 — 그리지 않음.

      // 나이(0→1): emit 직후 0 → 비행 끝/그 이후로 갈수록 1.
      final age = ((flyT - emitT) / (1.0 - emitT)).clamp(0.0, 1.0);
      // 피어남: 작게 시작→천천히 커짐(easeOut).
      final grow = Curves.easeOut.transform(age);
      final radius = (26 + grow * 52) * wobbleR;

      // 떠오름: 나이 들수록 살짝 위로 부유.
      final pos = _pathPoint(emitT) +
          perp * lateral +
          dir * along +
          Offset(0, -grow * 26);

      // 불투명도: 등장(빠르게 0→peak) 후 서서히 옅어짐 + done 흩어짐.
      final appear = (age / 0.25).clamp(0.0, 1.0);
      final fade = (1.0 - (age - 0.4).clamp(0.0, 1.0) / 0.6);
      final opacity =
          (0.42 * appear * fade * (1.0 - dissipate)).clamp(0.0, 1.0);
      if (opacity <= 0.01) continue;

      // done 흩어짐: 살짝 더 떠오르며 퍼짐.
      final driftPos = pos + Offset(0, -dissipate * 28);
      _puff(canvas, driftPos, radius * (1 + dissipate * 0.25), opacity,
          tintPick < 0.5 ? _cloudLavender : _cloudWhite);
    }

    // ── ② 덮는 구름 뱅크: t≳0.55부터 비행기 살짝 앞에 모여 비행기를 감싸 가림 ──
    final veil = ((flyT - 0.55) / 0.30).clamp(0.0, 1.0);
    if (veil > 0 || dissipate > 0) {
      final bankVeil = veil == 0 ? 1.0 : veil; // done에선 이미 1.
      // 비행기보다 진행 방향으로 살짝 앞(비행기가 그 속으로 들어감).
      final aheadT = (flyT + 0.06).clamp(0.0, 1.0);
      final bankCenter = _pathPoint(aheadT);
      final grow = Curves.easeInOut.transform(bankVeil);

      for (var i = 0; i < _bankCount; i++) {
        final ang = rnd.nextDouble() * 2 * pi;
        final rad = rnd.nextDouble() * (40 + grow * 46);
        final wobbleR = 0.9 + rnd.nextDouble() * 0.6;
        final pos = bankCenter +
            Offset(cos(ang), sin(ang)) * rad +
            Offset(0, -dissipate * 30);
        // 덮는 구름은 더 크고 짙게(비행기 occlusion).
        final radius = (60 + grow * 70) * wobbleR * (1 + dissipate * 0.2);
        final opacity = (0.78 * bankVeil * (1.0 - dissipate * 0.95))
            .clamp(0.0, 1.0);
        if (opacity <= 0.01) continue;
        _puff(canvas, pos, radius, opacity,
            i.isEven ? _cloudWhite : _cloudLavender);
      }
    }
  }

  // 단일 퍼프: radial gradient(중심 불투명→가장자리 투명) + soft blur로 몽환적.
  void _puff(
      Canvas canvas, Offset c, double r, double opacity, Color tint) {
    final rect = Rect.fromCircle(center: c, radius: r);
    final paint = Paint()
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.32)
      ..shader = RadialGradient(
        colors: [
          tint.withValues(alpha: opacity),
          tint.withValues(alpha: opacity * 0.55),
          tint.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(rect);
    canvas.drawCircle(c, r, paint);
  }

  @override
  bool shouldRepaint(covariant _CloudFieldPainter old) =>
      old.flyT != flyT ||
      old.dissipate != dissipate ||
      old.center != center ||
      old.dir != dir ||
      old.flySpeed != flySpeed;
}
