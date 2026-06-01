import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../../../core/haptics.dart';
import '../../../state/session.dart';
import '../../../theme/app_theme.dart';
import '../../complete/complete_screen.dart';
import '../widgets/paper_card.dart';
import '../widgets/particles.dart';

// ── 태우기 상태머신 (파쇄기 _Phase 동형) ──────────────────────────────────
/// idle → igniting(불씨 끌어올림) → burning(3초 자동 연소) → done.
enum _Phase { idle, igniting, burning, done }

// ── 점화/연소 임계 상수 (파쇄기 _kFeed* / _kGrindDuration 대응, §4.2) ──
/// 드래그 중 이 값 도달 시 즉시 점화(burning 진입).
const double _kIgniteThreshold = 0.85;

/// 드래그를 뗀 시점 이 값 이상이면 점화, 미만이면 idle 리셋(강요 없음).
const double _kIgniteCommit = 0.55;

/// 점화 확정 후 고정 연소 시간(드래그 무관). 파쇄기 _kGrindDuration과 동일값.
const Duration _kBurnDuration = Duration(milliseconds: 3000);

/// 전소→완료 화면 전이 지연(잔불 흰재가 잦아들 여운).
const Duration _kBurnToDone = Duration(milliseconds: 700);

// ── 흰 재 / 탄자국 로컬 색 (§8, app_theme 미수정) ──────────────────────────
// TODO(P1-token): 따뜻한 갈탄 — 남은 종이 하단 탄자국(어둡지 않게).
const Color _kCharWarm = Color(0xFF6E4A3A);
// TODO(P1-token): 흰 재 스노폴 팔레트(정화 톤). particles.emitSnowAsh 기본과 동일.
const List<Color> _kSnowAshPalette = [
  Color(0xFFF5F5F7),
  Color(0xFFFFFFFF),
  Color(0xFFE8E8EC),
];

/// RIT-01 태우기. 아래에서 불씨를 끌어올려 종이 하단에 갖다 대면 점화되고,
/// 이후 드래그와 무관하게 3초간 아래→위로 아주 큰 화력으로 활활 타오른다.
/// 진행도(0→1)가 종이 가시비율·불꽃 혀 높이·ember/흰재 방출·연속 햅틱을 단일
/// 축으로 구동한다(촉각 환상 유지). 흩날리는 재는 흰색(눈처럼 살랑 하강).
class BurnRitualScreen extends StatefulWidget {
  const BurnRitualScreen({super.key});

  @override
  State<BurnRitualScreen> createState() => _BurnRitualScreenState();
}

class _BurnRitualScreenState extends State<BurnRitualScreen>
    with TickerProviderStateMixin {
  // 파티클 루프(기존 유지) — 3초 연소는 별도 bounded 컨트롤러가 담당.
  late final Ticker _ticker;
  final _field = ParticleField();
  final _repaint = ValueNotifier(0);
  Duration _last = Duration.zero;

  static const _paperSize = Size(250, 340);
  Rect _paperRect = Rect.zero;

  _Phase _phase = _Phase.idle;
  double _ignite = 0; // igniting 동안 드래그로만 증가(점화 트리거 판정용).
  double _burn = 0; // burning 동안 3초 컨트롤러로 0→1(드래그 무관).

  // 3초 자동 연소 컨트롤러(반드시 bounded — unbounded()..repeat() 금지).
  late final AnimationController _burnCtrl;

  // 연속 연소 햅틱 핸들(haptics 소유 API, 호출만).
  BlazeHandle? _blazeHandle;

  // 흰 재 throttle 누적기(컨트롤러 value 기준). 매 프레임 과방출 방지.
  double _lastAshAt = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick)..start();
    _burnCtrl = AnimationController(vsync: this, duration: _kBurnDuration)
      ..addListener(_onBurnTick)
      ..addStatusListener(_onBurnStatus);
  }

  // ── 파티클 루프 틱 ────────────────────────────────────────────────────
  void _tick(Duration elapsed) {
    final dt =
        _last == Duration.zero ? 0.016 : (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;

    // 타는 동안 불씨(상승)·흰 재(하강)·연기를 현재 연소 경계 y에서 방출.
    if (_phase == _Phase.burning && _burn > 0 && _burn < 1 &&
        _paperRect != Rect.zero) {
      final burnY = _paperRect.bottom - _paperRect.height * _burn;
      final origin = Offset(_paperRect.center.dx, burnY);

      // ember: 진행도 비례로 활활(count 4→10).
      final emberCount = (4 + 6 * _burn).round();
      _field.emitEmber(
        origin: origin,
        count: emberCount,
        palette: const [AppColors.emberOrange, AppColors.emberYellow, Color(0xFFFF5722)],
      );

      // 흰 재 스노폴 + 옅은 연기: throttle 간격을 진행도로 가변(0.14s→0.06s),
      // count 2→5(후반 방출량↑). 연소선 전폭(width)으로 살포.
      final v = _burnCtrl.value;
      final intervalT =
          (0.14 - 0.08 * v) / _kBurnDuration.inSeconds; // value 기준 간격
      if (v - _lastAshAt >= intervalT) {
        _lastAshAt = v;
        final ashCount = (2 + 3 * v).round();
        _field.emitSnowAsh(
          origin: origin,
          width: _paperRect.width,
          count: ashCount,
          palette: _kSnowAshPalette,
        );
        // 연기는 톤이 어두우므로 빈도 절반(후반에만 가끔).
        if (v > 0.4) _field.emitSmoke(origin: origin, count: 1);
      }
    }

    _field.update(dt.clamp(0.0, 0.05));
    _repaint.value++;
  }

  // ── 3초 컨트롤러 리스너 ───────────────────────────────────────────────
  void _onBurnTick() {
    if (_phase != _Phase.burning) return;
    // 아래부터 천천히 붙다 위로 활활 가속 → easeIn.
    _burn = Curves.easeIn.transform(_burnCtrl.value);
    // 연속 햅틱: 컨트롤러 raw value를 주입(haptics 내부 곡선 적용).
    _blazeHandle?.setProgress(_burnCtrl.value);
    setState(() {}); // 종이 가시비율·불꽃 갱신.
  }

  void _onBurnStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _phase == _Phase.burning) {
      _complete();
    }
  }

  // ── 드래그(불씨 끌어올림 = 점화 트리거) ──────────────────────────────────
  void _onDragStart(DragStartDetails d) {
    if (_phase != _Phase.idle && _phase != _Phase.igniting) return;
    _phase = _Phase.igniting;
  }

  void _onDrag(DragUpdateDetails d) {
    if (_phase != _Phase.igniting) return; // burning/done 중 입력 무시.
    // 위로 끌수록 증가(primaryDelta 음수 → 증가). 종이 높이로 정규화.
    _ignite = (_ignite - d.primaryDelta! / _paperSize.height).clamp(0.0, 1.0);

    // 즉시 점화: 드래그 중 임계 도달.
    if (_ignite >= _kIgniteThreshold) {
      _enterBurning();
      return;
    }
    setState(() {}); // 예열 글로우 갱신.
  }

  void _onDragEnd(DragEndDetails d) {
    if (_phase != _Phase.igniting) return;
    if (_ignite >= _kIgniteCommit) {
      _enterBurning(); // 뗀 시점 커밋 임계 이상 → 점화 확정.
    } else {
      // 임계 미만에서 떼면 리셋(강요 없음, 햅틱·파티클 없음).
      setState(() {
        _phase = _Phase.idle;
        _ignite = 0;
      });
    }
  }

  // ── 전이: igniting → burning ──────────────────────────────────────────
  void _enterBurning() {
    if (_phase != _Phase.igniting) return;
    _phase = _Phase.burning;
    _burn = 0; // 컨트롤러 value 0→1을 _burn으로 매핑(점프 방지).
    _lastAshAt = 0;
    // 연속 연소 햅틱 시작(haptics 소유 API).
    _blazeHandle = Haptics.instance.startBurnBlaze();
    // 3초 고정 자동 연소 시작.
    _burnCtrl.forward(from: 0);
    setState(() {});
  }

  // ── 전이: burning → done (계약 순서 엄수, §4.5) ─────────────────────────
  void _complete() {
    if (_phase == _Phase.done || !mounted) return;
    _phase = _Phase.done;
    _burn = 1.0;

    // ★ stop()을 softSuccess 보다 반드시 먼저(겹침 방지).
    _blazeHandle?.stop();
    _blazeHandle = null;
    Haptics.instance.softSuccess();

    // 전소 정점 흰 재 버스트 1회(연소선 전폭으로 풍성하게).
    if (_paperRect != Rect.zero) {
      final topY = _paperRect.top;
      _field.emitSnowAsh(
        origin: Offset(_paperRect.center.dx, topY),
        width: _paperRect.width,
        count: 18,
        palette: _kSnowAshPalette,
      );
    }

    // 잔불 흰재가 잦아들 시간을 두고 완료 화면 전이.
    Future.delayed(_kBurnToDone, () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => const CompleteScreen(afterglow: _SnowAshAfterglow()),
      ));
    });
    setState(() {});
  }

  @override
  void dispose() {
    // 누수 0: 진동·타이머·컨트롤러·ticker 모두 정리.
    _blazeHandle?.stop();
    _burnCtrl.dispose();
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = SessionScope.of(context).text;
    final showHandle = _phase == _Phase.idle || _phase == _Phase.igniting;
    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, c) {
              _paperRect = Rect.fromCenter(
                center: Offset(c.maxWidth / 2, c.maxHeight * 0.42),
                width: _paperSize.width,
                height: _paperSize.height,
              );
              return Stack(
                children: [
                  // 종이: 아래가 타들어가 위쪽만 남음 + 하단 탄자국 그라데이션.
                  Positioned.fromRect(
                    rect: _paperRect,
                    child: ClipRect(
                      child: Align(
                        alignment: Alignment.topCenter,
                        heightFactor: (1 - _burn).clamp(0.0001, 1.0),
                        child: Stack(
                          children: [
                            PaperCard(
                                text: text,
                                width: _paperSize.width,
                                height: _paperSize.height),
                            // 탄자국: 따뜻한 갈탄 톤(어둡지 않게), 알파 완화(0.5).
                            Positioned.fill(
                              child: IgnorePointer(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(8),
                                    gradient: LinearGradient(
                                      begin: Alignment.bottomCenter,
                                      end: Alignment.topCenter,
                                      colors: [
                                        _kCharWarm.withValues(alpha: 0.5 * _burn),
                                        _kCharWarm.withValues(alpha: 0.0),
                                      ],
                                      stops: const [0.0, 0.4],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // 연소선(char 글로우 띠 + 큰 불꽃 혀) — 종이 위에 겹쳐 그림.
                  Positioned.fromRect(
                    rect: _paperRect,
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: BurnLinePainter(
                            burnValueOf: () => _burn, repaint: _repaint),
                      ),
                    ),
                  ),
                  // 불씨·흰재 파티클
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(painter: ParticlePainter(_field, _repaint)),
                    ),
                  ),
                  // 점화 전 예열 글로우(불씨 핸들이 종이 하단에 근접할수록).
                  if (_phase == _Phase.igniting && _ignite > 0)
                    Positioned(
                      left: (c.maxWidth - _paperSize.width) / 2,
                      top: _paperRect.bottom - 24,
                      width: _paperSize.width,
                      height: 48,
                      child: IgnorePointer(
                        child: Opacity(
                          opacity: (_ignite * 0.6).clamp(0.0, 0.6),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: RadialGradient(
                                colors: [
                                  AppColors.emberOrange.withValues(alpha: 0.5),
                                  AppColors.emberOrange.withValues(alpha: 0.0),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  // 안내 + 드래그 핸들: burning 이후 숨김(몰입·강요 금지).
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 48,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 300),
                      opacity: showHandle ? 1 : 0,
                      child: GestureDetector(
                        onVerticalDragStart: _onDragStart,
                        onVerticalDragUpdate: _onDrag,
                        onVerticalDragEnd: _onDragEnd,
                        behavior: HitTestBehavior.opaque,
                        child: const Column(
                          children: [
                            Icon(Icons.local_fire_department,
                                color: AppColors.emberOrange, size: 40),
                            SizedBox(height: 8),
                            Text('불씨를 위로 끌어올려 태워요',
                                style: TextStyle(color: Colors.white60)),
                          ],
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

/// 연소선 painter: 남은 종이 하단 경계에 char 글로우 띠 + 아주 큰 불꽃 혀.
/// 진행값은 [burnValueOf]로 매 프레임 읽고, repaint는 화면 틱(_repaint)에 묶어
/// 불꽃 혀가 항상 살아 움직이도록(idle 흔들림) 한다.
/// 아래는 굵고(베이스 넓게) 위로 갈수록 혀가 길고 격렬(높이 40~110px).
class BurnLinePainter extends CustomPainter {
  BurnLinePainter({required this.burnValueOf, required Listenable repaint})
      : super(repaint: repaint);

  /// 현재 연소 진행값(0→1)을 반환. 매 frame paint 시 최신값을 읽기 위한 콜백.
  final double Function() burnValueOf;

  @override
  void paint(Canvas canvas, Size size) {
    final progress = burnValueOf();
    if (progress <= 0 || progress >= 1) return;
    // 아래→위로 타므로 연소선 Y = 남은 종이의 하단 경계.
    final y = size.height * (1 - progress);

    // 1) char 글로우 띠: emberOrange→emberYellow 가로 그라데이션 + 큰 blur(14).
    final glow = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14)
      ..shader = const LinearGradient(
        colors: [
          AppColors.emberOrange,
          AppColors.emberYellow,
          AppColors.emberOrange,
        ],
      ).createShader(Rect.fromLTWH(0, y - 8, size.width, 16));
    canvas.drawRect(Rect.fromLTWH(0, y - 7, size.width, 14), glow);

    // 2) 불꽃 혀 2겹: 바깥(emberOrange, blur 큼) + 안쪽(emberYellow, 불투명).
    //    높이 = base(40~110px) * 혀별 sin 변조. 위상 속도↑로 격렬한 일렁임.
    const tongues = 13;
    final base = 40 + 70 * progress; // 아래 40px → 후반 110px
    Path buildFlame(double scale, double phase) {
      final path = Path()..moveTo(0, y);
      for (var i = 0; i <= tongues; i++) {
        final x = size.width * i / tongues;
        final phaseSeed = i * 1.9 + phase;
        final h = base * scale *
            (0.55 + 0.45 * sin(phaseSeed + progress * 26));
        path.lineTo(x, y - h);
        path.lineTo(size.width * (i + 0.5) / tongues, y);
      }
      path.lineTo(size.width, y);
      return path;
    }

    // 바깥 글로우 혀(더 크고 흐릿).
    final outer = Paint()
      ..color = AppColors.emberOrange.withValues(alpha: 0.7)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);
    canvas.drawPath(buildFlame(1.0, 0.0), outer);

    // 안쪽 노란 혀(불투명, 약간 작게).
    final inner = Paint()..color = AppColors.emberYellow.withValues(alpha: 0.92);
    canvas.drawPath(buildFlame(0.7, 0.8), inner);
  }

  @override
  bool shouldRepaint(covariant BurnLinePainter old) => true;
}

/// END-01 태우기 마무리: 흰 재가 눈처럼 부드럽게 내려오는 스노폴 잔상.
/// 🕯️ 촛불 대신 정화·따뜻 톤(어둡지 않게). 자체 Ticker로 흰 ashFlake가
/// 위→아래 살랑 낙하. CompleteScreen(afterglow:)로 주입(complete_screen 불변).
/// 누수 0: dispose에서 ticker 정리.
class _SnowAshAfterglow extends StatefulWidget {
  const _SnowAshAfterglow();

  @override
  State<_SnowAshAfterglow> createState() => _SnowAshAfterglowState();
}

class _SnowAshAfterglowState extends State<_SnowAshAfterglow> {
  late final Ticker _ticker;
  final _field = ParticleField(maxParticles: 120);
  final _repaint = ValueNotifier(0);
  Duration _last = Duration.zero;
  double _emitAccum = 0;
  // afterglow 박스 크기(CompleteScreen 180px Center 박스 내부에 가둠, §11-B).
  static const double _box = 180;

  @override
  void initState() {
    super.initState();
    _ticker = Ticker(_tick)..start();
  }

  void _tick(Duration elapsed) {
    final dt =
        _last == Duration.zero ? 0.016 : (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    // 박스 상단 전폭에서 흰 재를 천천히 방출(눈처럼 흩날림).
    _emitAccum += dt;
    if (_emitAccum >= 0.18) {
      _emitAccum = 0;
      _field.emitSnowAsh(
        origin: const Offset(_box / 2, -4),
        width: _box,
        count: 2,
        palette: _kSnowAshPalette,
      );
    }
    _field.update(dt.clamp(0.0, 0.05));
    _repaint.value++;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _box,
      height: _box,
      child: ClipRect(
        child: Stack(
          children: [
            // 은은한 흰/라벤더 글로우 베이스(어둡지 않게, 정화 톤).
            Center(
              child: Container(
                width: _box * 0.7,
                height: _box * 0.7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      AppColors.ballCore.withValues(alpha: 0.28),
                      AppColors.ballCore.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
            // 흰 재 스노폴.
            Positioned.fill(
              child: CustomPaint(painter: ParticlePainter(_field, _repaint)),
            ),
          ],
        ),
      ),
    );
  }
}
