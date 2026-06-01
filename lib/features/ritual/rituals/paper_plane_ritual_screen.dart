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

/// 비행 글라이드 길이.
const Duration _kFlyDuration = Duration(milliseconds: 1100);

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
  late final Animation<double> _flyCurve =
      CurvedAnimation(parent: _fly, curve: Curves.easeOutCubic);

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
      final dist = size.longestSide * (0.7 + _flySpeed * 0.7);
      final base = _flyDir * dist * t;
      // 살짝 떠올랐다 감속하는 lift + 말미로 잦아드는 좌우 wobble.
      final wobble = Offset(
        sin(t * pi * 2) * 18 * (1 - t),
        -sin(t * pi) * 40,
      );
      final offset = base + wobble;
      return Transform.translate(
        offset: offset,
        child: Transform.rotate(
          angle: _flyAngle,
          child: Transform.scale(
            scale: 1 - t * 0.7,
            child: Opacity(
              opacity: (1 - t).clamp(0.0, 1.0),
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

    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..setEntry(3, 2, _kPerspective)
        ..rotateX(noseTilt)
        ..scaleByDouble(wingNarrow, wingTall, 1, 1),
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
