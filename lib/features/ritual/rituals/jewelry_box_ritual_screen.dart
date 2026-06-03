import 'dart:math' as math;
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
/// idle(뚜껑 뒤로 젖혀 열림 + 종이 흩날림 + 함 하단) → dragging(종이를 함으로
/// 끌어내림) → inserting(종이가 열린 함 속으로 사라짐·이어 뚜껑 닫힘) →
/// rising(닫힘과 동시에 후광 펄스+심장박동 햅틱, 함이 두둥실 중앙으로 상승) →
/// done(중앙에서 둥실둥실 떠 빛나며 머묾 + 인플레이스 완료 멘트→버튼).
/// 간직형(keep) — 파괴가 아니라 보관. 함은 마지막에 사라지지 않고 중앙에 머문다.
/// 완료는 라우트 전환 없이 같은 화면에서(태우기 패턴 이식).
enum _Phase { idle, dragging, inserting, rising, done }

/// 종이 근접 임계 — 이 이상 끌면 삽입 확정, 미만이면 idle 리셋.
const double _kApproach = 220.0;
const double _kApproachThreshold = 0.8;

/// 함 상승(두둥실): 하단→중앙. 느리고 부드럽게(easeInOutSine), 둥실 떠오름.
/// (기존 900ms 급상승 → 느린 두둥실로 교체.)
const Duration _kRiseDuration = Duration(milliseconds: 2800);

/// 뚜껑 스프링 닫힘(easeOutBack, 점잖은 1회 오버슈트).
const Duration _kLidDuration = Duration(milliseconds: 600);

// ── 두둥실 bob / 후광 펄스(ticker clock의 sin으로 구동 — 별도 unbounded 금지) ──
/// 상하 부유 진폭(px)·주기(s). 느린 sine — '둥실둥실 떠 있는' 잔잔한 흔들림.
const double _kBobAmplitude = 8.0;
const double _kBobPeriod = 3.4;

/// 후광 펄스 주기(s). ~1초 주기로 부드럽게 커졌다 작아짐(심장박동 ~70bpm과 동조감).
const double _kHaloPulsePeriod = 0.86;

// ── 인플레이스 완료 타임라인(뚜껑 닫힘=0 기준) ───────────────────────────────
/// 닫힘=0 → 후광 펄스+심장박동+두둥실 상승 시작. ~2.8s 중앙 안착(이후도 두둥실).
/// ~3.5s 멘트 페이드인(이때 heartbeat.stop + success 1회). 그 뒤 ~1.3s 버튼.
const Duration _kMessageDelay = Duration(milliseconds: 3500);
const Duration _kMessageFade = Duration(milliseconds: 1400);
const Duration _kButtonDelay = Duration(milliseconds: 4800);
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
  late final AnimationController _lid; // 0(열림·뒤로 젖힘) → 1(닫힘)
  late final AnimationController _halo; // 후광 페이드인(닫힘 직후 등장)
  late final AnimationController _rise; // 하단→중앙 두둥실 상승(rising)
  late final Ticker _ticker; // 파티클 60fps 구동 + 후광 펄스/두둥실 clock
  late final Animation<double> _lidCurve; // 스프링 닫힘(easeOutBack)
  late final Animation<double> _riseCurve; // easeInOutSine(느린 두둥실)

  /// 후광이 떠 있는 동안 도는 심장박동 햅틱 핸들(닫힘~멘트 구간).
  /// haptics.dart의 startHeartbeat()가 반환. 멘트/도즈 안정화·dispose에서 stop.
  HeartbeatHandle? _heartbeat;

  Duration _lastTick = Duration.zero; // dt 산출용
  double _clock = 0; // ticker 누적 시간(초) — 후광 펄스/두둥실 bob 위상.
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

    _halo = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));

    _rise = AnimationController(vsync: this, duration: _kRiseDuration);
    // 느리고 부드러운 상승 — 양 끝이 잔잔히 가속/감속(두둥실 톤).
    _riseCurve = CurvedAnimation(parent: _rise, curve: Curves.easeInOutSine);
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
  /// 누적 _clock으로 후광 펄스(sin)·두둥실 bob(sin)을 구동(별도 unbounded 금지).
  void _onTick(Duration elapsed) {
    final dt = _lastTick == Duration.zero
        ? 0.016
        : (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    final cdt = dt.clamp(0.0, 0.05);
    _clock += cdt;

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
      _inserted = true; // 종이가 열린 함 입구로 들어가 사라짐.
      _phase = _Phase.inserting;
    });
    // 안치 순간: 부드러운 안착 + 함 입구 금빛 반짝이.
    Haptics.instance.fire(HapticLevel.light, throttle: false);
    _field.emitSparkle(origin: _boxCenter, count: 18, radius: 60);
    // 종이가 함 속으로 가라앉는 짧은 텀 뒤에 뚜껑이 앞으로 회전해 닫힌다.
    await Future.delayed(const Duration(milliseconds: 180));
    if (!mounted) return;
    await _lid.forward(); // 경첩축 앞으로 회전, 스프링(easeOutBack) 닫힘
    if (!mounted) return;
    // 뚜껑 닫힘 마무리: 부드러운 2펄스(keep 톤).
    Haptics.instance.softSuccess();
    _field.emitSparkle(origin: _boxCenter, count: 10, radius: 40);
    // 닫힘 완료 statusListener가 _enterRising()을 호출.
  }

  /// 뚜껑 닫힘=0 기준. 후광 등장+펄스, 심장박동 햅틱, 두둥실 상승을 동시 시작.
  /// 완료 멘트/버튼 타임라인도 여기(닫힘 기준)서 예약한다 — 상승 길이와 무관하게
  /// '닫힘 후 ~3.5s 멘트'가 보장되도록.
  void _enterRising() {
    if (_phase != _Phase.inserting || !mounted) return;
    setState(() => _phase = _Phase.rising);
    // 후광이 닫힘 직후 부드럽게 등장(이후 매 프레임 sin 펄스로 번쩍번쩍).
    _halo.forward(from: 0);
    // 후광이 번쩍이는 동안 심장박동 햅틱이 연속으로 돈다(따뜻·부드럽게 폰 전반).
    // '처음으로'를 누를 때까지(=화면 떠날 때까지) 계속 — _backToHome·dispose에서 stop.
    // 안전장치를 길게(10분) 줘서 멘트·버튼 표시 동안에도 끊기지 않게.
    _heartbeat?.stop();
    _heartbeat =
        Haptics.instance.startHeartbeat(safety: const Duration(minutes: 10));
    _rise.forward(from: 0);

    // ── 인플레이스 완료 시퀀스(라우트 전환 없음 — 같은 화면에 머문다) ──
    // 닫힘=0 기준 ~3.5s 멘트, ~4.8s 버튼.
    Future.delayed(_kMessageDelay, () {
      if (!mounted) return;
      // 심장박동은 '처음으로' 누를 때까지 계속 유지(여기서 멈추지 않는다).
      // 멘트 등장에 보관 완료의 따뜻한 success 1회만 얹는다(태우기 완료 톤).
      Haptics.instance.fire(HapticLevel.success, throttle: false);
      setState(() => _showMessage = true);
    });
    Future.delayed(_kButtonDelay, () {
      if (!mounted) return;
      setState(() => _showButton = true);
    });
  }

  /// 상승 완료 → done 페이즈(이후 중앙에서 두둥실 + 후광 펄스 지속).
  /// 완료 멘트/버튼은 _enterRising에서 닫힘 기준으로 이미 예약됨.
  void _enterDone() {
    if (_phase != _Phase.rising || !mounted) return;
    setState(() => _phase = _Phase.done);
  }

  // '처음으로': 세션 리셋 + 홈 복귀(burn _backToHome과 동일).
  void _backToHome() {
    // '처음으로' 탭 = 의식 종료 → 여기서 심장박동(후광 심박)을 멈춘다.
    _heartbeat?.stop();
    _heartbeat = null;
    SessionScope.of(context).reset();
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  void dispose() {
    // 누수 0: 심장박동 햅틱·ticker·컨트롤러·notifier 모두 정리.
    _heartbeat?.stop();
    _heartbeat = null;
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

              // 모든 시변(時變) 모션을 한 AnimatedBuilder로 묶어 매 프레임 갱신.
              // _repaint(ticker clock)로 후광 펄스·두둥실 bob을 구동하고,
              // _lid/_halo/_rise 컨트롤러 보간도 함께 반영(리빌드 범위 최소화).
              return AnimatedBuilder(
                animation: Listenable.merge([_repaint, _lid, _halo, _rise]),
                builder: (context, _) {
              // 상승 보간(easeInOutSine, 느린 두둥실). rising 이전엔 0, done엔 1.
              final riseT = (_phase == _Phase.done) ? 1.0 : _riseCurve.value;
              // 두둥실 bob — rising/done에서 잔잔한 sine 상하(±_kBobAmplitude).
              // 상승이 진행될수록(riseT) 부유감이 차오르고, done에선 계속 떠 있다.
              final floating = _phase == _Phase.rising || _phase == _Phase.done;
              final bob = floating
                  ? math.sin(_clock * 2 * math.pi / _kBobPeriod) *
                      _kBobAmplitude *
                      (_phase == _Phase.done ? 1.0 : riseT)
                  : 0.0;
              final boxCenter =
                  Offset.lerp(_restCenter, _screenCenter, riseT)! +
                      Offset(0, bob);
              _boxCenter = boxCenter;
              final scale = ui.lerpDouble(1.0, 1.15, riseT)!;

              // 후광 펄스: 닫힘 직후 _halo로 등장(0→1), 이후 매 프레임 sin으로
              // 밝기가 ~1초 주기로 부드럽게 커졌다 작아짐(번쩍번쩍, 부드럽게).
              final pulse = floating
                  ? 0.5 + 0.5 * math.sin(_clock * 2 * math.pi / _kHaloPulsePeriod)
                  : 0.0;
              // 베이스 0.55 + 펄스 0.40 스윙 → alpha ~0.55~0.95 사이로 출렁.
              // _halo.value(0→1, 700ms)로 닫힘 직후 부드럽게 등장한다.
              final haloAlpha = (0.55 + 0.40 * pulse) * _halo.value;
              // 펄스에 맞춰 반경도 살짝 호흡(360~400px).
              final haloRadius = 360 + 40 * pulse;

              // ── 함 입구(mouth) 기하 — 종이가 '쏙' 빨려드는 목표/클립 기준 ──
              // 페인터 좌표(206×158): frontTop=72, 입구 앞턱(lip front)=frontTop,
              // 입구 뒤모서리=frontTop-_topFaceH. 함 left=boxCenter.dx-103,
              // top=boxCenter.dy-70. scale은 boxCenter(=함 중심부) 기준이 아니라
              // Positioned 좌상단 기준이므로 입구 y에 (scale-1) 보정은 미미 — idle
              // (scale≈1)에서 정밀히 맞추고 상승 구간엔 _inserted라 종이는 없음.
              const painterFrontTop = 156.0 - 84.0; // = 72
              const painterTopFaceH = 16.0;
              final boxTopLeftY = boxCenter.dy - 70;
              // 입구 앞턱(클립 라인): 이 y '아래'로 내려간 종이 부분은 함 속으로
              // 사라진다(앞벽 뒤로 들어감). 살짝 위(=뒤모서리쪽)로 잡아 입구 안으로
              // 빨려드는 느낌을 강조.
              final mouthClipY = boxTopLeftY +
                  (painterFrontTop - painterTopFaceH * 0.4) * scale;
              // 종이가 빨려드는 목표 중심(입구 안 살짝 아래). cavity 중앙 근처.
              final mouthCenterY = boxTopLeftY +
                  (painterFrontTop - painterTopFaceH * 0.5) * scale;

                  // 종이 변형값(approachT에 따라 입구로 빨려듦).
                  // 시작 위치: 화면 상단부. 목표: 입구 중심으로 수렴.
                  final paperStartY = c.maxHeight * 0.42 - 160 + 150; // 카드 중심.
                  final paperCenterY =
                      ui.lerpDouble(paperStartY, mouthCenterY, _approachT)!;
                  final paperScale = ui.lerpDouble(1.0, 0.18, _approachT)!;
                  // 원근으로 상단이 뒤로 눕는 rotateX(입구로 빨려드는 느낌).
                  final paperTilt = _approachT * 0.95; // 라디안(≈54°).
                  // 팔랑~: 빨려드는 동안 좌우로 살랑이며 흔들림(낙엽처럼 안으로 들어감).
                  // 진폭은 진입 중반에 최대→입구 근처(approachT→1)엔 잦아들어 안착.
                  final flutterEnv = math.sin(_approachT * math.pi);
                  final flutterZ =
                      math.sin(_clock * 7.5) * 0.22 * flutterEnv; // 좌우 기울임(rad)
                  final flutterX =
                      math.sin(_clock * 5.5 + 0.7) * 26 * flutterEnv; // 가로 드리프트(px)

              return Stack(
                alignment: Alignment.center,
                children: [
                  // ── 후광(함 뒤 RadialGradient, 금빛 펄스) ──
                  Positioned(
                    left: boxCenter.dx - haloRadius / 2,
                    top: boxCenter.dy - haloRadius / 2,
                    child: IgnorePointer(
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

                  // ── 종이(입구로 빨려들며 함 속으로 담김) ──
                  // z-순서 핵심: [후광/cavity 어둠] → 〈종이〉 → [함 앞벽·뚜껑·금테].
                  // 종이는 함 painter '아래'(=뒤)에 쌓이고, ClipRect로 입구 라인
                  // (mouthClipY) 위쪽만 보이게 잘라 — 내려간(이미 들어간) 부분은
                  // 입구 안으로 사라진다(앞벽 뒤로 들어가 담기는 모핑).
                  if (!_inserted)
                    Positioned.fill(
                      child: ClipRect(
                        clipper: _MouthClipper(mouthClipY),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Positioned(
                              // Transform(alignment:center)가 박스 중심 기준 변형
                              // → 레이아웃 중심을 paperCenterY에 두면 변형 후에도
                              //   시각 중심이 paperCenterY에 고정(카드 높이 300).
                              top: paperCenterY - 150,
                              child: GestureDetector(
                                onVerticalDragUpdate: _onDrag,
                                onVerticalDragEnd: _onDragEnd,
                                child: Transform(
                                  alignment: Alignment.center,
                                  transform: Matrix4.identity()
                                    ..translateByDouble(flutterX, 0.0, 0.0, 1.0)
                                    ..setEntry(3, 2, 0.0014)
                                    ..rotateX(paperTilt)
                                    ..rotateZ(flutterZ)
                                    ..scaleByDouble(
                                        paperScale, paperScale, 1.0, 1.0),
                                  child: PaperCard(
                                      text: text, width: 220, height: 300),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // ── 3D 입체 보석함(두둥실 상승하며 살짝 커짐) ──
                  // 종이보다 '위'(=앞)에 그려져 앞벽·뚜껑·금테가 종이를 가린다 →
                  // 입구 아래로 내려간 종이는 함 속으로 들어가 보인다.
                  Positioned(
                    left: boxCenter.dx - 103,
                    top: boxCenter.dy - 70,
                    child: Transform.scale(
                      scale: scale,
                      child: IgnorePointer(
                        child: CustomPaint(
                          size: const Size(206, 158),
                          painter: _JewelryBoxPainter(lid: _lidCurve.value),
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
              );
            },
          ),
        ),
      ),
    );
  }
}

// ── 입구 클립: y=mouthY '위쪽'만 보이게 잘라 종이가 입구 아래로 사라지게 ──
/// 종이 레이어를 함 입구 라인(mouthY) 위쪽만 남기고 잘라낸다. 드래그로 종이가
/// 입구로 내려가면 mouthY '아래' 부분이 클립에 먹혀 함 속(앞벽 뒤)으로 사라진다.
/// 진짜 함 통째 뒤로 숨는 게 아니라 '입구로 빨려드는' 모핑의 핵심.
class _MouthClipper extends CustomClipper<Rect> {
  const _MouthClipper(this.mouthY);

  /// 입구 앞턱 y(이 아래로 내려간 종이는 보이지 않음).
  final double mouthY;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(0, 0, size.width, mouthY.clamp(0.0, size.height));

  @override
  bool shouldReclip(covariant _MouthClipper old) => old.mouthY != mouthY;
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

    // ── ⑥ 어두운 내부 캐비티(뚜껑이 열린 만큼 입구로 보임) ──
    _drawCavity(canvas, cx, frontTop, topInset);

    // ── ⑦ 뚜껑(뒤쪽 경첩축 rotateX 열림→닫힘 + 광택) ──
    _drawLid(canvas, cx, frontTop);
  }

  /// 함 입구의 어두운 내부. 뚜껑이 열릴수록(l→0) 입구가 위로 더 열려 깊게 보인다.
  /// 윗면(원근 사다리꼴)의 안쪽에 어두운 사다리꼴을 깔아 '뚜껑 열어둔 보석함' 느낌.
  void _drawCavity(Canvas canvas, double cx, double frontTop, double topInset) {
    final open = 1 - lid.clamp(0.0, 1.0); // 1=완전 열림.
    if (open <= 0.001) return; // 닫히면 캐비티 숨김.
    // 입구 깊이: 열릴수록 위로 더 깊게(최대 _topFaceH + 22).
    final mouthDepth = _topFaceH + 22 * open;
    final lipY = frontTop - _topFaceH; // 윗면 상변(입구 뒤쪽 모서리).
    final innerL = cx - _boxW / 2 + topInset;
    final innerR = cx + _boxW / 2 - topInset;
    // 입구 사다리꼴: 앞(아래·넓게) → 뒤(위·살짝 좁게), 어두운 안쪽.
    final cavity = Path()
      ..moveTo(innerL + 4, frontTop) // 앞 좌
      ..lineTo(innerR - 4, frontTop) // 앞 우
      ..lineTo(innerR - 10, lipY - (mouthDepth - _topFaceH)) // 뒤 우
      ..lineTo(innerL + 10, lipY - (mouthDepth - _topFaceH)) // 뒤 좌
      ..close();
    // 안쪽 음영 그라데이션(앞은 덜 어둡고 뒤로 갈수록 깊은 어둠).
    canvas.drawPath(
      cavity,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            const Color(0xFF35244B).withValues(alpha: 0.9 * open + 0.1),
            const Color(0xFF1C1230).withValues(alpha: open),
          ],
        ).createShader(Rect.fromLTRB(
            innerL, lipY - (mouthDepth - _topFaceH), innerR, frontTop)),
    );
    // 입구 앞턱 금빛 림(빛 받는 모서리).
    canvas.drawLine(
      Offset(innerL + 4, frontTop),
      Offset(innerR - 4, frontTop),
      Paint()
        ..color = _gold.withValues(alpha: 0.5 * open)
        ..strokeWidth = 1.2,
    );
  }

  /// 뚜껑: 본체 뒤쪽 경첩을 축으로 뒤로 젖혀 열림(l=0) ↔ 앞으로 회전해 닫힘(l=1).
  /// 열린 상태에선 뚜껑이 뒤로 ~80° 젖혀져 안쪽 캐비티가 드러난다.
  void _drawLid(Canvas canvas, double cx, double frontTop) {
    final l = lid.clamp(0.0, 1.0);
    // 닫힘 진행에 따라 뒤로 젖힌 회전과 약간의 들림이 0으로 수렴.
    // 열림(l=0): 뒤쪽 경첩축으로 ~80°(1.4rad) 젖혀 입구가 위로 열리고 캐비티가 보임.
    final lift = (1 - l) * 30; // 경첩이 살짝 위로 들렸다 안착.
    final tilt = (1 - l) * 1.4; // rotateX(라디안) — 열림 시 깊게 뒤로 젖힘.

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
