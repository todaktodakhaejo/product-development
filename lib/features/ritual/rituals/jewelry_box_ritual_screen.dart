import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../../../core/haptics.dart';
import '../../../core/strings.dart';
import '../../../state/session.dart';
import '../../../theme/app_theme.dart';
import '../widgets/paper_card.dart';
import '../widgets/particles.dart';

// ── 보석함 상태머신 ──────────────────────────────────────────────────────────
/// idle(종이 흩날림 float + 함 하단) → dragging(종이를 함으로 끌어내림) →
/// inserting(종이 사라짐·뚜껑 닫힘) → rising(함이 후광 두르고 중앙으로 상승) →
/// done(중앙에 빛나며 머묾 + 인플레이스 완료 멘트→버튼).
/// 간직형(keep) — 파괴가 아니라 보관. 함은 마지막에 사라지지 않고 중앙에 머문다.
/// 완료는 라우트 전환 없이 같은 화면에서(태우기 패턴 이식).
enum _Phase { idle, dragging, inserting, rising, done }

/// 종이 근접 임계 — 이 이상 끌면 삽입 확정, 미만이면 idle 리셋.
const double _kApproach = 220.0;
const double _kApproachThreshold = 0.8;

/// 함 상승: 하단→중앙. easeOutCubic, 부드럽게 떠오름.
const Duration _kRiseDuration = Duration(milliseconds: 900);

/// 뚜껑 스프링 닫힘(easeOutBack, 점잖은 1회 오버슈트).
const Duration _kLidDuration = Duration(milliseconds: 600);

// ── 인플레이스 완료 타임라인(rising 완료=0 기준) ─────────────────────────────
/// 함이 중앙에서 빛나는 여운 뒤 멘트 페이드인(+success 햅틱 1회).
/// 보석함은 burn의 '재 흩날림 3초 홀드'가 없어 단축(간직 잔향 ~1.8s).
const Duration _kMessageDelay = Duration(milliseconds: 1800);
const Duration _kMessageFade = Duration(milliseconds: 1400);
const Duration _kButtonDelay = Duration(milliseconds: 3200);
const Duration _kButtonFade = Duration(milliseconds: 800);

// ── 함 idle/중앙 기준 위치(화면 높이 비율) ──────────────────────────────────
const double _kRestY = 0.68; // idle: 하단.
const double _kCenterY = 0.46; // done: 시각적 정중앙(멘트 공간 고려 약간 위).

// ── 3D 보석함 로컬 보석톤 팔레트(app_theme 미수정 — burn _kCharWarm 선례) ──
const Color _kBoxFrontTop = Color(0xFF7E5BA6); // 정면 밝은 보라.
const Color _kBoxFrontBottom = Color(0xFF5A3E78); // 정면 짙은 보라.
const Color _kBoxLidTop = Color(0xFF9B79C4); // 뚜껑 밝은 면.
const Color _kBoxLidBottom = Color(0xFF7E5BA6); // 뚜껑 아래.
const Color _kBoxTopFace = Color(0xFF8E6BB6); // 윗면(광원 위 — 가장 밝음).
const Color _kBoxSideFace = Color(0xFF4C3468); // 측면(음영 — 가장 어두움).
const Color _kJewelLight = Color(0xFFD9C6F0); // jewel facet 밝은면.
const Color _kJewelDark = Color(0xFF9B79C4); // jewel facet 어두운면.

/// RIT-10 보석함 보관. 종이를 함에 끌어 넣고 뚜껑을 닫으면, 함이 후광을 두르고
/// 화면 정중앙으로 떠올라 빛나며 머문다(간직형). 완료는 같은 화면에서.
class JewelryBoxRitualScreen extends StatefulWidget {
  const JewelryBoxRitualScreen({super.key});

  @override
  State<JewelryBoxRitualScreen> createState() => _JewelryBoxRitualScreenState();
}

class _JewelryBoxRitualScreenState extends State<JewelryBoxRitualScreen>
    with TickerProviderStateMixin {
  late final AnimationController _lid; // 0(열림) → 1(닫힘)
  late final AnimationController _halo; // 후광 페이드인(inserting에서)
  late final AnimationController _rise; // 하단→중앙 상승(rising)
  late final Ticker _ticker; // 파티클 60fps 구동(unbounded.repeat 금지)
  late final Animation<double> _lidCurve; // 스프링 닫힘(easeOutBack)
  late final Animation<double> _riseCurve; // easeOutCubic

  Duration _lastTick = Duration.zero; // dt 산출용
  final _field = ParticleField(maxParticles: 120);
  final _repaint = ValueNotifier(0);

  _Phase _phase = _Phase.idle;
  double _drag = 0; // 종이를 아래로 끈 거리
  bool _inserted = false;
  bool _snapped = false; // 스냅 햅틱 1회 가드
  double _riseSparkleAccum = 0; // 상승 중 sparkle throttle 누적(초)

  // 함 좌표(현재 프레임 build에서 갱신). sparkle origin·상승 보간 기준.
  Offset _restCenter = Offset.zero;
  Offset _screenCenter = Offset.zero;
  Offset _boxCenter = Offset.zero; // 현재(보간된) 함 중심.

  // 인플레이스 완료 토글.
  bool _showMessage = false;
  bool _showButton = false;

  @override
  void initState() {
    super.initState();
    _lid = AnimationController(vsync: this, duration: _kLidDuration);
    _lidCurve = CurvedAnimation(parent: _lid, curve: Curves.easeOutBack);
    _lid.addStatusListener((s) {
      // 뚜껑 닫힘 완료 → 상승 시작.
      if (s == AnimationStatus.completed && _phase == _Phase.inserting) {
        _enterRising();
      }
    });

    _halo = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

    _rise = AnimationController(vsync: this, duration: _kRiseDuration);
    _riseCurve = CurvedAnimation(parent: _rise, curve: Curves.easeOutCubic);
    _rise.addStatusListener((s) {
      if (s == AnimationStatus.completed && _phase == _Phase.rising) {
        _enterDone();
      }
    });

    // 파티클 갱신용 틱(burn·shredder와 동일하게 Ticker 직접 구동).
    // ※ AnimationController.unbounded()..repeat()는 lowerBound -∞로
    //   '_initialT >= 0.0' assertion 크래시 이력 → Ticker로 직접 구동한다.
    _ticker = createTicker(_onTick)..start();
  }

  /// 매 프레임 파티클 적분 + 리페인트. 상승 중엔 잔잔한 sparkle를 throttle 방출.
  void _onTick(Duration elapsed) {
    final dt = _lastTick == Duration.zero
        ? 0.016
        : (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    final cdt = dt.clamp(0.0, 0.05);

    // 상승 중 잔잔한 금빛 반짝이(과하지 않게 ~120ms throttle).
    if (_phase == _Phase.rising && _boxCenter != Offset.zero) {
      _riseSparkleAccum += cdt;
      if (_riseSparkleAccum >= 0.12) {
        _riseSparkleAccum = 0;
        _field.emitSparkle(origin: _boxCenter, count: 5, radius: 50);
      }
    }

    _field.update(cdt);
    _repaint.value++;
  }

  double get _approachT => (_drag / _kApproach).clamp(0.0, 1.0);

  void _onDrag(DragUpdateDetails d) {
    if (_phase != _Phase.idle && _phase != _Phase.dragging) return;
    if (_phase == _Phase.idle) _phase = _Phase.dragging;
    setState(() => _drag = (_drag + d.primaryDelta!).clamp(0.0, _kApproach));
    // 함 근처 임계 진입 순간 1회만 부드러운 스냅 햅틱(자석처럼 살짝 끌림).
    if (!_snapped && _approachT >= _kApproachThreshold) {
      _snapped = true;
      Haptics.instance.fire(HapticLevel.selection);
    } else if (_snapped && _approachT < _kApproachThreshold) {
      _snapped = false; // 다시 멀어지면 재무장
    }
  }

  void _onDragEnd(DragEndDetails d) {
    if (_phase != _Phase.dragging) return;
    if (_approachT >= _kApproachThreshold) {
      _insert();
    } else {
      // 임계 미만 → idle 리셋(되돌릴 수 있음 보장).
      setState(() {
        _drag = 0;
        _snapped = false;
        _phase = _Phase.idle;
      });
    }
  }

  Future<void> _insert() async {
    setState(() {
      _inserted = true;
      _phase = _Phase.inserting;
    });
    // 안치 순간: 부드러운 안착 + 금빛 반짝이.
    Haptics.instance.fire(HapticLevel.light, throttle: false);
    _field.emitSparkle(origin: _boxCenter, count: 18, radius: 60);
    // 삽입과 동시에 후광이 은은히 켜진다(이후 rising에서 강화).
    _halo.forward();
    await Future.delayed(const Duration(milliseconds: 120));
    if (!mounted) return;
    await _lid.forward(); // 스프링(easeOutBack) 닫힘
    if (!mounted) return;
    // 뚜껑 닫힘 마무리: 부드러운 2펄스(keep 톤).
    Haptics.instance.softSuccess();
    _field.emitSparkle(origin: _boxCenter, count: 10, radius: 40);
    // 닫힘 완료 statusListener가 _enterRising()을 호출.
  }

  void _enterRising() {
    if (_phase != _Phase.inserting || !mounted) return;
    setState(() => _phase = _Phase.rising);
    // 상승 시작 단발 햅틱(은은한 swell — 연속 진동 엔진 불필요).
    Haptics.instance.fire(HapticLevel.medium, throttle: false);
    // 후광이 풀 밝기까지 마저 켜지도록(보간은 _riseCurve 기준으로 강화).
    if (_halo.status != AnimationStatus.completed) _halo.forward();
    _rise.forward(from: 0);
  }

  void _enterDone() {
    if (_phase != _Phase.done && _phase != _Phase.rising) return;
    if (!mounted) return;
    setState(() => _phase = _Phase.done);
    // ── 인플레이스 완료 시퀀스(라우트 전환 없음 — 같은 화면에 머문다) ──
    Future.delayed(_kMessageDelay, () {
      if (!mounted) return;
      Haptics.instance.fire(HapticLevel.success, throttle: false);
      setState(() => _showMessage = true);
    });
    Future.delayed(_kButtonDelay, () {
      if (!mounted) return;
      setState(() => _showButton = true);
    });
  }

  // '처음으로': 세션 리셋 + 홈 복귀(burn _backToHome과 동일).
  void _backToHome() {
    SessionScope.of(context).reset();
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  void dispose() {
    // 누수 0: ticker·컨트롤러·notifier 모두 정리.
    _ticker.dispose();
    _repaint.dispose();
    _lid.dispose();
    _halo.dispose();
    _rise.dispose();
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
              _restCenter = Offset(c.maxWidth / 2, c.maxHeight * _kRestY);
              _screenCenter = Offset(c.maxWidth / 2, c.maxHeight * _kCenterY);

              // 상승 보간(easeOutCubic). rising 이전엔 0, done엔 1.
              final riseT = (_phase == _Phase.done) ? 1.0 : _riseCurve.value;
              final boxCenter = Offset.lerp(_restCenter, _screenCenter, riseT)!;
              _boxCenter = boxCenter;
              final scale = ui.lerpDouble(1.0, 1.18, riseT)!;

              // 후광 강도: 삽입에서 _halo로 켜지고, 상승에서 riseT로 강화.
              // alpha 0.6→0.95, 반경 320→380.
              final haloAlpha = (0.6 + 0.35 * riseT) * _halo.value;
              final haloRadius = ui.lerpDouble(320, 380, riseT)!;

              return Stack(
                alignment: Alignment.center,
                children: [
                  // ── 후광(함 뒤 RadialGradient, 금빛) ──
                  Positioned(
                    left: boxCenter.dx - haloRadius / 2,
                    top: boxCenter.dy - haloRadius / 2,
                    child: AnimatedBuilder(
                      animation: Listenable.merge([_halo, _rise]),
                      builder: (_, __) => IgnorePointer(
                        child: Container(
                          width: haloRadius,
                          height: haloRadius,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(colors: [
                              AppColors.emberYellow.withValues(alpha: haloAlpha),
                              Colors.transparent,
                            ]),
                          ),
                        ),
                      ),
                    ),
                  ),

                  // ── 종이(끌어내릴수록 작아지며 함으로) ──
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

                  // ── 3D 입체 보석함(상승하며 살짝 커짐) ──
                  Positioned(
                    left: boxCenter.dx - 103,
                    top: boxCenter.dy - 70,
                    child: AnimatedBuilder(
                      animation: Listenable.merge([_lid, _rise]),
                      builder: (_, __) => Transform.scale(
                        scale: scale,
                        child: IgnorePointer(
                          child: CustomPaint(
                            size: const Size(206, 158),
                            painter: _JewelryBoxPainter(lid: _lidCurve.value),
                          ),
                        ),
                      ),
                    ),
                  ),

                  // ── sparkle 파티클 ──
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: ParticlePainter(_field, _repaint),
                      ),
                    ),
                  ),

                  // ── 안내/간직 카피(완료 멘트 전까지) — 하단 ──
                  if (_phase != _Phase.done)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 40,
                      child: IgnorePointer(
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 300),
                          opacity: 1,
                          child: Text(
                            _inserted
                                ? '소중히 간직할게요'
                                : '종이를 보석함으로 끌어내려요',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white60),
                          ),
                        ),
                      ),
                    ),

                  // ── 완료 멘트(인플레이스 페이드인) — 하단 1/3(후광 비가림) ──
                  if (_phase == _Phase.done)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 140,
                      child: IgnorePointer(
                        child: AnimatedOpacity(
                          duration: _kMessageFade,
                          curve: Curves.easeInOut,
                          opacity: _showMessage ? 1.0 : 0.0,
                          child: const Column(
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

// ════════════════════════════════════════════════════════════════════════════
// 3D 입체 보석함 painter(이모지 제거). 살짝 위에서 내려다보는 1점 원근.
// 면 구성(아래→위): 정면(그라데이션) + 윗면(밝은 사다리꼴) + 측면(어두운 사다리꼴)
//   + 뚜껑(광택, 경첩 rotateX 열림→닫힘) + 금테 + 직접 그린 jewel facet.
// 좌표계: canvas 206×158. 본체 정면은 하단, 뚜껑은 그 위.
// ════════════════════════════════════════════════════════════════════════════
class _JewelryBoxPainter extends CustomPainter {
  _JewelryBoxPainter({required this.lid});

  /// 뚜껑 닫힘 진행도 0(열림)→1(닫힘). easeOutBack로 1을 넘을 수 있어 clamp.
  final double lid;

  static const double _boxW = 200; // 본체 정면 폭.
  static const double _frontH = 84; // 정면 높이.
  static const double _topFaceH = 16; // 윗면(사다리꼴) 높이.
  static const double _sideW = 10; // 우측 측면 폭.
  static const double _lidW = 206; // 뚜껑 폭(살짝 넓게 덮음).
  static const double _lidH = 44; // 뚜껑 높이.
  static const Color _gold = AppColors.emberYellow;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    // 본체 정면을 캔버스 하단에 배치. 정면 상단 y = bottom - frontH.
    final frontBottom = size.height - 2;
    final frontTop = frontBottom - _frontH;
    final frontLeft = cx - _boxW / 2;
    final frontRight = cx + _boxW / 2;

    // ── ① 우측 측면(가장 어두운 음영면, 1점 원근 사다리꼴) ──
    // 정면 우상단에서 안쪽 위로 들어가는 작은 사다리꼴.
    final sidePath = Path()
      ..moveTo(frontRight, frontTop)
      ..lineTo(frontRight - _sideW, frontTop - _topFaceH)
      ..lineTo(frontRight - _sideW, frontBottom - _topFaceH * 0.5)
      ..lineTo(frontRight, frontBottom - 14)
      ..close();
    canvas.drawPath(sidePath, Paint()..color = _kBoxSideFace);

    // ── ② 윗면(원근 사다리꼴, 광원 위 — 가장 밝은 면) ──
    // 하변 = 정면 상단 폭(200), 상변은 안쪽으로 좁아짐(172).
    const topInset = (_boxW - 172) / 2; // 좌우로 들어가는 양.
    final topFacePath = Path()
      ..moveTo(frontLeft, frontTop) // 하변 좌
      ..lineTo(frontRight, frontTop) // 하변 우
      ..lineTo(frontRight - topInset, frontTop - _topFaceH) // 상변 우
      ..lineTo(frontLeft + topInset, frontTop - _topFaceH) // 상변 좌
      ..close();
    canvas.drawPath(topFacePath, Paint()..color = _kBoxTopFace);
    // 윗면 상변 림 하이라이트.
    canvas.drawLine(
      Offset(frontLeft + topInset, frontTop - _topFaceH),
      Offset(frontRight - topInset, frontTop - _topFaceH),
      Paint()
        ..color = const Color(0x55FFFFFF)
        ..strokeWidth = 1.5,
    );

    // ── ③ 본체 정면(그라데이션 밝은 보라→짙은 보라) ──
    final frontRect = RRect.fromRectAndCorners(
      Rect.fromLTRB(frontLeft, frontTop, frontRight, frontBottom),
      bottomLeft: const Radius.circular(12),
      bottomRight: const Radius.circular(12),
      topLeft: const Radius.circular(3),
      topRight: const Radius.circular(3),
    );
    canvas.drawRRect(
      frontRect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_kBoxFrontTop, _kBoxFrontBottom],
        ).createShader(
            Rect.fromLTRB(frontLeft, frontTop, frontRight, frontBottom)),
    );
    // 좌측 상단 사선 글로스 띠(claymorphism 광택감).
    canvas.save();
    canvas.clipRRect(frontRect);
    final glossPath = Path()
      ..moveTo(frontLeft, frontTop)
      ..lineTo(frontLeft + 60, frontTop)
      ..lineTo(frontLeft + 22, frontBottom)
      ..lineTo(frontLeft, frontBottom)
      ..close();
    canvas.drawPath(
      glossPath,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0x33FFFFFF), Color(0x00FFFFFF)],
        ).createShader(
            Rect.fromLTRB(frontLeft, frontTop, frontLeft + 60, frontBottom)),
    );
    canvas.restore();

    // ── ④ 정면 jewel facet(직접 그린 작은 다이아 컷) ──
    _drawJewel(canvas, Offset(cx, frontTop + _frontH * 0.55), 12);

    // ── ⑤ 금테 보더(본체 정면 외곽) ──
    canvas.drawRRect(
      frontRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = _gold.withValues(alpha: 0.6),
    );

    // ── ⑥ 뚜껑(경첩 rotateX 열림→닫힘 + 광택) ──
    _drawLid(canvas, cx, frontTop);
  }

  /// 뚜껑: 경첩이 본체 뒤쪽에 있는 듯 위로 들렸다 내려오며 rotateX로 닫힘.
  void _drawLid(Canvas canvas, double cx, double frontTop) {
    final l = lid.clamp(0.0, 1.0);
    // 닫힘 진행에 따라 위로 들린 높이(top 오프셋)와 X축 회전이 0으로 수렴.
    final lift = (1 - l) * 54; // 위로 들렸다 내려옴.
    final tilt = (1 - l) * 0.9; // rotateX(라디안).

    // 뚜껑은 본체 정면 상단(윗면 위)에 안착. 닫힘 시 뚜껑 하단 = frontTop - topFaceH.
    final lidBottom = frontTop - _topFaceH;
    final lidLeft = cx - _lidW / 2;

    canvas.save();
    // 경첩(뚜껑 뒤 하단) 기준 원근 회전.
    final hingeY = lidBottom - lift;
    canvas.translate(cx, hingeY);
    // 1점 원근 rotateX 근사(Matrix4 perspective).
    final m = Matrix4.identity()
      ..setEntry(3, 2, 0.0012)
      ..rotateX(tilt);
    canvas.transform(m.storage);
    canvas.translate(-cx, -hingeY);

    final lidTop = hingeY - _lidH;
    final lidRect = RRect.fromRectAndCorners(
      Rect.fromLTRB(lidLeft, lidTop, lidLeft + _lidW, hingeY),
      topLeft: const Radius.circular(12),
      topRight: const Radius.circular(12),
      bottomLeft: const Radius.circular(3),
      bottomRight: const Radius.circular(3),
    );
    canvas.drawRRect(
      lidRect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_kBoxLidTop, _kBoxLidBottom],
        ).createShader(
            Rect.fromLTRB(lidLeft, lidTop, lidLeft + _lidW, hingeY)),
    );
    // 뚜껑 상단 광택 곡선(곡면감).
    canvas.save();
    canvas.clipRRect(lidRect);
    final glossRect = Rect.fromLTWH(lidLeft, lidTop, _lidW, _lidH * 0.5);
    final gloss = Path()
      ..moveTo(lidLeft + 14, lidTop + _lidH * 0.42)
      ..quadraticBezierTo(
        cx, lidTop + 4,
        lidLeft + _lidW - 14, lidTop + _lidH * 0.42,
      )
      ..quadraticBezierTo(
        cx, lidTop + _lidH * 0.30,
        lidLeft + 14, lidTop + _lidH * 0.42,
      )
      ..close();
    canvas.drawPath(
      gloss,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x66FFFFFF), Color(0x00FFFFFF)],
        ).createShader(glossRect),
    );
    canvas.restore();

    // 금테(뚜껑 외곽).
    canvas.drawRRect(
      lidRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = _gold.withValues(alpha: 0.7),
    );
    // 뚜껑↔본체 경첩 금선(뚜껑 하단).
    canvas.drawLine(
      Offset(lidLeft + 6, hingeY),
      Offset(lidLeft + _lidW - 6, hingeY),
      Paint()
        ..color = _gold.withValues(alpha: 0.85)
        ..strokeWidth = 1.5,
    );
    canvas.restore();
  }

  /// 직접 그린 jewel facet — 6각 다이아 컷(밝은면/어두운면 분할 + 중심 스파클).
  void _drawJewel(Canvas canvas, Offset c, double r) {
    final top = Offset(c.dx, c.dy - r);
    final bottom = Offset(c.dx, c.dy + r * 1.2);
    final ul = Offset(c.dx - r * 0.9, c.dy - r * 0.35);
    final ur = Offset(c.dx + r * 0.9, c.dy - r * 0.35);
    final ll = Offset(c.dx - r * 0.55, c.dy + r * 0.4);
    final lr = Offset(c.dx + r * 0.55, c.dy + r * 0.4);

    // 좌(밝은면): top-ul-ll-bottom.
    final left = Path()
      ..moveTo(top.dx, top.dy)
      ..lineTo(ul.dx, ul.dy)
      ..lineTo(ll.dx, ll.dy)
      ..lineTo(bottom.dx, bottom.dy)
      ..close();
    canvas.drawPath(left, Paint()..color = _kJewelLight);

    // 우(어두운면): top-ur-lr-bottom.
    final right = Path()
      ..moveTo(top.dx, top.dy)
      ..lineTo(ur.dx, ur.dy)
      ..lineTo(lr.dx, lr.dy)
      ..lineTo(bottom.dx, bottom.dy)
      ..close();
    canvas.drawPath(right, Paint()..color = _kJewelDark);

    // facet 경계선(금빛).
    final outline = Path()
      ..moveTo(top.dx, top.dy)
      ..lineTo(ul.dx, ul.dy)
      ..lineTo(ll.dx, ll.dy)
      ..lineTo(bottom.dx, bottom.dy)
      ..lineTo(lr.dx, lr.dy)
      ..lineTo(ur.dx, ur.dy)
      ..close();
    canvas.drawPath(
      outline,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..color = _gold.withValues(alpha: 0.85),
    );
    // 중심을 가르는 세로 + 윗 가로 facet선.
    canvas.drawLine(
      top, bottom,
      Paint()
        ..color = _gold.withValues(alpha: 0.6)
        ..strokeWidth = 0.6,
    );
    canvas.drawLine(
      ul, ur,
      Paint()
        ..color = _gold.withValues(alpha: 0.5)
        ..strokeWidth = 0.6,
    );
    // 중심 스파클 점.
    canvas.drawCircle(
      Offset(c.dx - r * 0.2, c.dy - r * 0.15),
      1.6,
      Paint()..color = const Color(0xFFFFFFFF),
    );
  }

  @override
  bool shouldRepaint(covariant _JewelryBoxPainter old) => old.lid != lid;
}
