import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../../../core/haptics.dart';
import '../../../core/strings.dart';
import '../../../state/session.dart';
import '../../../theme/app_theme.dart';
import '../widgets/paper_card.dart';
import '../widgets/particles.dart';

// ── 태우기 상태머신 ───────────────────────────────────────────────────────
/// idle → igniting(불꽃 드래그) → burning(3초 자동 연소) → done(전체 재).
/// 레퍼런스(burn_advanced.html)의 흐름을 그대로 옮긴다:
/// 1) 하단의 큰 3겹 불꽃을 위로 드래그 → 2) 불꽃 상단이 종이 하단에 **닿는 순간**
/// 즉시 점화(드래그 거리 임계 아님) → 3) 종이가 아래→위로 부드럽게 사라지며
/// 글로잉 char 띠 + 밝은 rim 상승·종이 떨림·불티 솟음 → 4) 전소 후 화면 전체에
/// 흰 재가 눈처럼 지속 → 5) **인플레이스 오버레이**(라우트 전환 없음)로 완료 멘트
/// 페이드인 → '처음으로' 버튼 페이드인. burn 화면에 그대로 머문다.
enum _Phase { idle, igniting, burning, done }

/// 점화 확정 후 고정 연소 시간(드래그 무관). 사용자 합의값 3초 유지(레퍼런스 ~2.4s).
const Duration _kBurnDuration = Duration(milliseconds: 3000);

// ── 완료 인플레이스 오버레이 타임라인(전소=0 기준) ──────────────────────────
/// 전소 후 멘트가 떠오르기 전 재 흩날림만 보여주는 홀드(레퍼런스 released-msg).
const Duration _kMessageDelay = Duration(milliseconds: 3000);

/// 멘트 페이드인 시간(opacity 0→1, ease).
const Duration _kMessageFade = Duration(milliseconds: 1400);

/// 멘트가 다 뜬 뒤 '처음으로' 버튼이 뜨기까지의 추가 지연(전소 기준 ≈4.4s).
const Duration _kButtonDelay = Duration(milliseconds: 4400);

/// '처음으로' 버튼 페이드인 시간(opacity 0→1).
const Duration _kButtonFade = Duration(milliseconds: 800);

/// 불꽃 스프링 복귀(미점화 후 손 뗌) 시간 — 레퍼런스 cubic-bezier(0.34,1.56,0.64,1).
const Duration _kFlameReturn = Duration(milliseconds: 600);

// ── 전폭 '불의 벽'(연소 중) 기하 ───────────────────────────────────────────
/// 종이 좌우로 넘쳐 감싸 올라가는 폭(±). 종이 폭(250)에 더해진다.
const double _kWallOverflow = 12;
/// 벽 box 높이(가장 큰 혀 + 베이스 글로우 여유). box bottom=burnY 근처.
const double _kWallHeight = 200;

// ── 흰 재 / 탄자국 로컬 색 (app_theme 미수정) ──────────────────────────────
// 따뜻한 갈탄 — 남은 종이 하단 탄자국(어둡지 않게).
const Color _kCharWarm = Color(0xFF6E4A3A);
// 흰 재 스노폴 팔레트(정화 톤). particles.emitSnowAsh 기본과 동일.
const List<Color> _kSnowAshPalette = [
  Color(0xFFF5F5F7),
  Color(0xFFFFFFFF),
  Color(0xFFE8E8EC),
];

/// RIT-01 태우기. 레퍼런스의 드래그 가능한 3겹 불꽃 + 마스크 연소 + char 띠/rim +
/// ember + 전체 재 눈을 Flutter로 재현. 배경/완료흐름/햅틱 API는 불변(호출만).
class BurnRitualScreen extends StatefulWidget {
  const BurnRitualScreen({super.key});

  @override
  State<BurnRitualScreen> createState() => _BurnRitualScreenState();
}

class _BurnRitualScreenState extends State<BurnRitualScreen>
    with TickerProviderStateMixin {
  // 파티클 루프 + 불꽃 flicker 구동 ticker(60fps 공통). 3초 연소는 bounded 컨트롤러.
  late final Ticker _ticker;
  // 전소 후 화면 전체 눈 흩날림을 위해 cap 상향(320).
  final _field = ParticleField(maxParticles: 320);
  final _repaint = ValueNotifier(0);
  Duration _last = Duration.zero;

  // flicker용 누적 시간(불꽃 painter가 살아 움직이도록 매 프레임 증가).
  double _clock = 0;

  static const _paperSize = Size(250, 340);
  Rect _paperRect = Rect.zero;
  Size _screen = Size.zero;

  // ── 불꽃 기하 (레퍼런스 flame-handle 220×280, 하단 bottom:80) ──────────
  static const Size _flameBox = Size(220, 280);
  static const double _flameBottomGap = 56; // SafeArea 하단에서 띄움.
  Rect _flameRestRect = Rect.zero; // idle 위치(드래그 origin).

  _Phase _phase = _Phase.idle;

  /// 불꽃의 세로 오프셋(px). 위로만 이동(레퍼런스 flameY = min(0, ...)).
  double _flameY = 0;
  bool _flameEngulf = false; // 점화 시 불꽃이 커지며 flicker 가속.

  // 불꽃 스프링 복귀 컨트롤러(미점화 후 손 뗌). bounded.
  late final AnimationController _flameReturnCtrl;
  double _flameReturnFrom = 0;

  // 드래그 추적.
  double? _dragStartGlobalY;
  double _dragStartFlameY = 0;

  double _burn = 0; // burning 동안 0→1(드래그 무관). 마스크/edge/rim 위치.

  // done 단계 전폭 눈 방출 throttle 누적기(초).
  double _snowAccum = 0;
  // 연소 중 흰 재 throttle(컨트롤러 value 기준).
  double _lastAshAt = 0;

  // 3초 자동 연소 컨트롤러(bounded — unbounded()..repeat() 금지).
  late final AnimationController _burnCtrl;

  // 연속 연소 햅틱 핸들(haptics 소유 API, 호출만).
  BlazeHandle? _blazeHandle;

  // 힌트(화살표·문구) 페이드(점화 시 0).
  bool get _showHint => _phase == _Phase.idle || _phase == _Phase.igniting;

  // ── 완료 인플레이스 오버레이 시퀀스 토글(전소 후 Future.delayed로 구동) ──
  bool _showMessage = false; // t=3.0s 멘트 페이드인.
  bool _showButton = false; // t≈4.4s '처음으로' 버튼 페이드인.

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick)..start();
    _burnCtrl = AnimationController(vsync: this, duration: _kBurnDuration)
      ..addListener(_onBurnTick)
      ..addStatusListener(_onBurnStatus);
    _flameReturnCtrl =
        AnimationController(vsync: this, duration: _kFlameReturn)
          ..addListener(_onFlameReturnTick);
  }

  // ── 파티클 + flicker 루프 틱 ──────────────────────────────────────────
  void _tick(Duration elapsed) {
    final dt =
        _last == Duration.zero ? 0.016 : (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    _clock += dt;

    // 타는 동안 불티(상승)·흰 재(하강)를 현재 연소 경계 y에서 방출.
    if (_phase == _Phase.burning &&
        _burn > 0 &&
        _burn < 1 &&
        _paperRect != Rect.zero) {
      final burnY = _paperRect.bottom - _paperRect.height * _burn;
      final origin = Offset(_paperRect.center.dx, burnY);

      // ember: 연소 중 매 프레임 ~85% 확률 방출(레퍼런스). 진행도 비례 count.
      if (_clock > 0 && (_clock * 997).floor() % 100 < 85) {
        final emberCount = (3 + 5 * _burn).round();
        _field.emitEmber(
          origin: origin,
          count: emberCount,
          palette: const [
            AppColors.emberOrange,
            AppColors.emberYellow,
            Color(0xFFFF5722),
          ],
        );
      }

      // 흰 재 스노폴: throttle 간격을 진행도로 가변. 연소선 전폭(70%) 살포.
      final v = _burnCtrl.value;
      final intervalT = (0.14 - 0.08 * v) / _kBurnDuration.inSeconds;
      if (v - _lastAshAt >= intervalT) {
        _lastAshAt = v;
        final ashCount = (2 + 3 * v).round();
        _field.emitSnowAsh(
          origin: origin,
          width: _paperRect.width * 0.7,
          count: ashCount,
          palette: _kSnowAshPalette,
        );
      }
    }

    // done 단계: 화면 상단 전폭에서 흰 눈을 지속 방출 → 화면 전체에 은은히 흩날림.
    // 라우트 전환을 없애 화면이 오래 머물므로, 방출 밀도를 차분히 낮춰(눈처럼 은은)
    // 멘트·버튼이 뜬 뒤에도 거슬리지 않게 계속 살아있게 한다(재는 흰색 유지).
    if (_phase == _Phase.done && _screen != Size.zero) {
      _snowAccum += dt;
      if (_snowAccum >= 0.10) {
        _snowAccum = 0;
        _field.emitSnowAsh(
          origin: Offset(_screen.width / 2, -8),
          width: _screen.width,
          count: 3,
          palette: _kSnowAshPalette,
        );
      }
    }

    _field.update(dt.clamp(0.0, 0.05));
    _repaint.value++;
  }

  // ── 3초 컨트롤러 리스너 ───────────────────────────────────────────────
  void _onBurnTick() {
    if (_phase != _Phase.burning) return;
    // 레퍼런스: 일정 속도(speed*dt). 살짝 가속감만 주려 easeInOutSine 근사 대신
    // 선형에 가깝게(균일 연소). 곧게 위로 사라지도록 raw value 사용.
    _burn = _burnCtrl.value;
    _blazeHandle?.setProgress(_burnCtrl.value);
    setState(() {}); // 마스크 stop·edge/rim 위치 갱신.
  }

  void _onBurnStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _phase == _Phase.burning) {
      _complete();
    }
  }

  // ── 불꽃 스프링 복귀 리스너 ───────────────────────────────────────────
  void _onFlameReturnTick() {
    // easeOutBack류(레퍼런스 cubic-bezier(0.34,1.56,0.64,1))로 0까지 복귀.
    final t = Curves.elasticOut.transform(_flameReturnCtrl.value);
    setState(() {
      _flameY = _flameReturnFrom * (1 - t);
    });
  }

  // ── 드래그(불꽃 끌어올림 = 점화 트리거) ──────────────────────────────────
  void _onDragStart(DragStartDetails d) {
    if (_phase != _Phase.idle && _phase != _Phase.igniting) return;
    _flameReturnCtrl.stop();
    _phase = _Phase.igniting;
    _dragStartGlobalY = d.globalPosition.dy;
    _dragStartFlameY = _flameY;
    // 불꽃 잡기 햅틱.
    Haptics.instance.fire(HapticLevel.light);
    setState(() {});
  }

  void _onDrag(DragUpdateDetails d) {
    if (_phase != _Phase.igniting || _dragStartGlobalY == null) return;
    final dy = d.globalPosition.dy - _dragStartGlobalY!;
    // 위로만 이동(레퍼런스 flameY = min(0, initialFlameY + dy)).
    _flameY = min(0.0, _dragStartFlameY + dy);

    // 충돌 점화: 불꽃 상단(top + 높이 15%)이 종이 하단에 닿으면 즉시.
    final flameTopY = _flameRestRect.top + _flameY + _flameBox.height * 0.15;
    if (_paperRect != Rect.zero && flameTopY <= _paperRect.bottom) {
      _enterBurning();
      return;
    }
    setState(() {});
  }

  void _onDragEnd(DragEndDetails d) {
    if (_phase != _Phase.igniting) return;
    // 점화 안 됨 → 스프링으로 하단 복귀.
    _dragStartGlobalY = null;
    if (_flameY < 0) {
      _flameReturnFrom = _flameY;
      _flameReturnCtrl.forward(from: 0);
    }
    setState(() => _phase = _Phase.idle);
  }

  // ── 전이: igniting → burning ──────────────────────────────────────────
  void _enterBurning() {
    if (_phase != _Phase.igniting) return;
    _dragStartGlobalY = null;
    _phase = _Phase.burning;
    _burn = 0;
    _lastAshAt = 0;
    _flameEngulf = true; // 불꽃 engulf(커지며 flicker 가속).

    // ★ 점화 순간 강한 임팩트(레퍼런스 Haptic.impact). heavy + medium 두께.
    Haptics.instance.fire(HapticLevel.heavy, throttle: false);
    Haptics.instance.fire(HapticLevel.medium, throttle: false);

    // 화르륵 초기 ember burst(레퍼런스 20개).
    if (_paperRect != Rect.zero) {
      _field.emitEmber(
        origin: Offset(_paperRect.center.dx, _paperRect.bottom),
        count: 20,
        palette: const [
          AppColors.emberOrange,
          AppColors.emberYellow,
          Color(0xFFFF5722),
        ],
      );
    }

    // 연속 연소 햅틱 시작(haptics 소유 API).
    _blazeHandle = Haptics.instance.startBurnBlaze();
    // 3초 고정 자동 연소 시작.
    _burnCtrl.forward(from: 0);
    setState(() {});
  }

  // ── 전이: burning → done (계약 순서 엄수) ──────────────────────────────
  void _complete() {
    if (_phase == _Phase.done || !mounted) return;
    _phase = _Phase.done;
    _burn = 1.0;

    // ★ stop()을 softSuccess 보다 반드시 먼저(겹침 방지 계약).
    // 연소 햅틱은 즉시 멈추되, 등장 성공 햅틱은 멘트가 떠오르는 순간에 1회
    // 발사한다(아래 _kMessageDelay 콜백). 여기선 stop만.
    _blazeHandle?.stop();
    _blazeHandle = null;

    // 전소 지점에서 위로 솟는 큰 ember 버스트(레퍼런스 complete 30개) + 흰재 whoosh.
    if (_paperRect != Rect.zero) {
      _field.emitEmber(
        origin: Offset(_paperRect.center.dx, _paperRect.top),
        count: 30,
        palette: const [
          AppColors.emberOrange,
          AppColors.emberYellow,
          Color(0xFFFF5722),
        ],
      );
      _field.emitBurst(
        origin: Offset(_paperRect.center.dx, _paperRect.top),
        count: 60,
        palette: _kSnowAshPalette,
        speed: 360,
        sizeMin: 3,
        sizeMax: 7,
        life: 2.6,
        shape: ParticleShape.ashFlake,
        gravity: 60,
        spread: pi * 1.2,
        baseAngle: -pi / 2,
      );
    }
    // 화면 상단 전폭에서 흰 눈 즉시 대량 1회 방출(전환 시작 임팩트).
    if (_screen != Size.zero) {
      _field.emitSnowAsh(
        origin: Offset(_screen.width / 2, -8),
        width: _screen.width,
        count: 40,
        palette: _kSnowAshPalette,
      );
    }

    // ── 인플레이스 완료 시퀀스(라우트 전환 없음 — 같은 burn 화면에 머문다) ──
    // 재가 ~3초 은은히 흩날린 뒤 멘트 페이드인(+success 햅틱 1회), 그 뒤 버튼.
    Future.delayed(_kMessageDelay, () {
      if (!mounted) return;
      // 멘트가 떠오르는 순간 부드러운 success 햅틱 1회(기존 CompleteScreen 톤).
      Haptics.instance.fire(HapticLevel.success, throttle: false);
      setState(() => _showMessage = true);
    });
    Future.delayed(_kButtonDelay, () {
      if (!mounted) return;
      setState(() => _showButton = true);
    });
    setState(() {});
  }

  // ── '처음으로': 세션 리셋 + 홈 복귀(기존 _backToHome 동작과 동일) ──
  void _backToHome() {
    SessionScope.of(context).reset();
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  void dispose() {
    // 누수 0: 진동·타이머·컨트롤러·ticker 모두 정리.
    _blazeHandle?.stop();
    _burnCtrl.dispose();
    _flameReturnCtrl.dispose();
    _ticker.dispose();
    _repaint.dispose();
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
              _screen = Size(c.maxWidth, c.maxHeight);
              // 종이는 상단에 둔다(레퍼런스 top:22%). 작은 화면에서도 불꽃과
              // 충분한 드래그 갭이 생기도록 상단 고정 오프셋 + 화면 비율 보정.
              final paperTop = (c.maxHeight * 0.16).clamp(56.0, 160.0);
              _paperRect = Rect.fromLTWH(
                (c.maxWidth - _paperSize.width) / 2,
                paperTop,
                _paperSize.width,
                _paperSize.height,
              );
              // 불꽃 idle 위치: 화면 하단 중앙(box 220×280).
              // 단, 작은 화면에서도 종이와 명확한 드래그 갭이 생기도록 불꽃의
              // 시각 top(box top + 15%)이 종이 하단보다 최소 _kRestGap 아래에
              // 오도록 box top을 정한다(하단 gap은 충분할 때만 적용).
              const restGap = 110.0;
              final flameVisualTopOffset = _flameBox.height * 0.15;
              // 원하는 box top = paperBottom + restGap - 시각top오프셋.
              final desiredTop =
                  _paperRect.bottom + restGap - flameVisualTopOffset;
              // 화면 하단 gap 기준 top과 비교해 더 아래(큰 값)를 택한다.
              final bottomGapTop =
                  c.maxHeight - _flameBox.height - _flameBottomGap;
              final flameTop = max(desiredTop, bottomGapTop);
              _flameRestRect = Rect.fromLTWH(
                (c.maxWidth - _flameBox.width) / 2,
                flameTop,
                _flameBox.width,
                _flameBox.height,
              );
              // 연소 중엔 종이 가로 폭 전체를 채우는 '불의 벽'이 연소선(burnY)을
              // 따라 위로 올라간다 — 종이를 통째로 타고 오르고, 이미 탄 아래쪽엔
              // 불이 남지 않는다. idle/igniting에선 단일 불씨를 드래그한 위치 그대로.
              final bool wall =
                  _phase == _Phase.burning || _phase == _Phase.done;
              final Rect flameRect;
              if (wall) {
                final burnY = _paperRect.bottom - _paperRect.height * _burn;
                // 폭: 종이 폭 + 좌우 overflow(종이를 감싸 올라가는 느낌).
                final wallW = _paperSize.width + _kWallOverflow * 2;
                // 벽 base(box bottom)를 연소선 살짝 아래에 둔다 → 불이 burnY에서
                // 시작해 위로 솟고, burnY 아래(이미 탄 곳)엔 불이 없다.
                final wallBottom = burnY + 6;
                flameRect = Rect.fromLTWH(
                  (c.maxWidth - wallW) / 2,
                  wallBottom - _kWallHeight,
                  wallW,
                  _kWallHeight,
                );
              } else {
                flameRect = _flameRestRect.shift(Offset(0, _flameY));
              }

              // 점화 후 불꽃 페이드아웃(done에서 천천히 사라짐).
              final flameOpacity = _phase == _Phase.done ? 0.0 : 1.0;

              return Stack(
                children: [
                  // ── 종이: 마스크로 아래→위 부드럽게 녹아 사라짐 ──
                  // done(전소)에선 종이가 완전히 사라진 상태이므로 본체·마스크·
                  // inner-shadow·char를 **아예 렌더하지 않는다**(테두리/hairline
                  // 잔상 0). 완료 멘트 단계에서 종이 외곽선이 '훑이는' 현상 차단.
                  if (_phase != _Phase.done && _burn < 1.0)
                    Positioned.fromRect(
                      rect: _paperRect,
                      child: IgnorePointer(
                        child: _BurningPaper(
                          text: text,
                          size: _paperSize,
                          burn: _burn,
                          burning: _phase == _Phase.burning,
                          clock: _clock,
                        ),
                      ),
                    ),

                  // ── 불티·흰재 파티클 ──
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                          painter: ParticlePainter(_field, _repaint)),
                    ),
                  ),

                  // ── 상향 화살표 힌트(bobbing) ──
                  if (_showHint)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: _flameRestRect.top - 52,
                      child: IgnorePointer(
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 400),
                          opacity: _phase == _Phase.igniting ? 0.0 : 1.0,
                          child: Center(
                            child: _BobbingArrow(clock: _clock),
                          ),
                        ),
                      ),
                    ),

                  // ── 드래그 가능한 3겹 불꽃 ──
                  Positioned.fromRect(
                    rect: flameRect.inflate(0),
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 2000),
                      opacity: flameOpacity,
                      child: GestureDetector(
                        onVerticalDragStart: _onDragStart,
                        onVerticalDragUpdate: _onDrag,
                        onVerticalDragEnd: _onDragEnd,
                        behavior: HitTestBehavior.opaque,
                        child: CustomPaint(
                          painter: FlamePainter(
                            clock: () => _clock,
                            engulfOf: () => _flameEngulf,
                            wallOf: () => wall,
                            repaint: _repaint,
                          ),
                        ),
                      ),
                    ),
                  ),

                  // ── 안내 문구(점화 시 페이드아웃) ──
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 16,
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 300),
                        opacity: _showHint ? 1 : 0,
                        child: const Text(
                          '불꽃을 종이로 가져가요',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white60, fontSize: 14),
                        ),
                      ),
                    ),
                  ),

                  // ── 완료 멘트(인플레이스 페이드인) — 재 위 화면 중앙 ──
                  // CompleteScreen과 동일 카피·스타일. 어두운 배경 위 가독성 위해
                  // 살짝 그림자. 멘트가 다 떠야 버튼이 뜨므로 IgnorePointer.
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

// ════════════════════════════════════════════════════════════════════════
// 불타는 종이: ShaderMask 소프트 그라데이션 + burn-edge(char 띠) + burn-rim.
// ════════════════════════════════════════════════════════════════════════

/// 레퍼런스의 `.paper-body` mask-image + `.burn-edge` + `.burn-rim` + tremble을
/// 한 위젯으로 묶는다. burn(0→1)이 아래에서 위로 종이를 부드럽게 지운다.
class _BurningPaper extends StatelessWidget {
  const _BurningPaper({
    required this.text,
    required this.size,
    required this.burn,
    required this.burning,
    required this.clock,
  });

  final String text;
  final Size size;
  final double burn; // 0→1 (연소 진행, 아래에서 위로).
  final bool burning;
  final double clock;

  @override
  Widget build(BuildContext context) {
    // tremble: 타는 동안 미세 translate+rotate(레퍼런스 paper-tremble 0.18s).
    Offset trans = Offset.zero;
    double rot = 0;
    if (burning) {
      final ph = clock / 0.18; // 0.18s 주기
      trans = Offset(sin(ph * 6.28) * 1.0, cos(ph * 6.28 * 1.3) * 1.0);
      rot = sin(ph * 6.28 * 0.7) * 0.005; // ~±0.3deg
    }

    // burn mask: 아래 burn%까지 투명 → +12% 부드러운 전이 → 위 불투명.
    final masked = ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) {
        final b = burn.clamp(0.0, 1.0);
        // 종이 윗변 hairline 방지: b가 1에 가까워지면 '불투명' 색마저 투명으로
        // 페이드해, b=1 직전 stops가 [.., 1, 1, 1]로 뭉쳐 맨 위 1px opaque
        // 선(테두리)이 남는 현상을 없앤다. b<0.85에선 완전 불투명(정상 마스크).
        final topAlpha =
            (1.0 - ((b - 0.85) / 0.15)).clamp(0.0, 1.0); // 0.85→1, 1.0→0
        final opaque = Color.fromRGBO(255, 255, 255, topAlpha);
        // 세로: y=1(아래)에서 위로 b만큼 투명, +0.12 전이.
        // LinearGradient bottom→top. 아래(0.0)=투명, 위=불투명.
        return LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            const Color(0x00FFFFFF),
            const Color(0x00FFFFFF),
            opaque,
            opaque,
          ],
          stops: [
            0.0,
            b,
            (b + 0.12).clamp(0.0, 1.0),
            1.0,
          ],
        ).createShader(rect);
      },
      child: Stack(
        children: [
          // ⚠️ shadow:false — PaperCard의 boxShadow(black54, blur24)는 종이 영역
          // 밖으로 번지므로 ShaderMask가 잡지 못해 종이가 다 타도 어두운 사각형
          // 후광/프레임으로 남는다. 그림자를 끄고(잔상 0), 점화 전 깊이감은
          // 아래 _idleDepth(마스크 안쪽 inner shadow)로 대체한다.
          // float: 점화 전(idle/igniting)엔 다른 의식처럼 흩날림, 연소 시작하면
          // _BurningPaper 자체 tremble이 주가 되도록 끔(중복·과함 방지).
          PaperCard(
            text: text,
            width: size.width,
            height: size.height,
            shadow: false,
            float: !burning,
          ),
          // 점화 전(idle/igniting) 은은한 깊이감: 마스크 안쪽 요소라 종이와 함께
          // 깔끔히 사라진다. 연소 시작과 함께 burn에 비례해 fade-out.
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 300),
                opacity: burning ? 0.0 : 1.0,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x33000000),
                        blurRadius: 10,
                        offset: Offset(0, 4),
                        spreadRadius: -4,
                        blurStyle: BlurStyle.inner,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // 하단 탄자국: 따뜻한 갈탄(어둡지 않게), 연소선 근처만.
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    _kCharWarm.withValues(alpha: 0.45 * burn),
                    _kCharWarm.withValues(alpha: 0.0),
                  ],
                  stops: const [0.0, 0.35],
                ),
              ),
            ),
          ),
        ],
      ),
    );

    // burn-edge(char 띠) + burn-rim은 마스크 밖(위)에 그려야 잘리지 않으므로
    // ShaderMask 바깥 Stack으로 겹친다. 연소 중에만 표시.
    return Transform.translate(
      offset: trans,
      child: Transform.rotate(
        angle: rot,
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: Stack(
            children: [
              // 마스크된 종이 본문. 연소 경계의 불은 연소선을 따라 올라가는
              // 3겹 불꽃이 담당하므로, 별도의 밝은 rim/깜빡이는 char 띠는 그리지
              // 않는다(종이는 소프트 마스크로 깨끗이 녹아 사라짐 — 번쩍이는
              // 테두리 제거).
              Positioned.fill(child: masked),
            ],
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// FlamePainter: 레퍼런스 3겹 불꽃(outer/mid/core) + 독립 flicker + engulf.
// screen blend 느낌을 겹친 반투명 RadialGradient로 근사(BlendMode.plus).
// ════════════════════════════════════════════════════════════════════════

/// 화면 하단의 크고 부드러운 3겹 불꽃(단일, idle/igniting) — 불씨를 종이로
/// 옮기는 단계. box 좌표계 안에서 바닥 중앙을 기준으로 위로 솟는다.
/// `wallOf()==true`(burning/done)이면 단일 불꽃 대신 종이 폭 전체를 채우는
/// **불의 벽**(가로로 배열된 큰 혀 + 베이스 글로우 띠, 3겹 두께감)을 그린다.
/// 벽의 base(box bottom)가 연소선(burnY)에 위치하므로 _burn 0→1에 따라 같이
/// 위로 상승하고, box bottom 아래(이미 탄 곳)엔 불이 없다.
class FlamePainter extends CustomPainter {
  FlamePainter({
    required this.clock,
    required this.engulfOf,
    required this.wallOf,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final double Function() clock;
  final bool Function() engulfOf;
  final bool Function() wallOf;

  // ── 전폭 불벽 파라미터 ──────────────────────────────────────────────────
  static const int _tongueCount = 10; // 가로로 배열되는 큰 혀 수.
  static const double _tongueMinH = 84; // 혀 최소 높이.
  static const double _tongueMaxH = 158; // 혀 최대 높이(활활).

  @override
  void paint(Canvas canvas, Size size) {
    if (wallOf()) {
      _paintWall(canvas, size);
      return;
    }
    _paintSingle(canvas, size);
  }

  // ── 단일 불꽃(idle/igniting): 불씨를 옮기는 단계 ─────────────────────────
  void _paintSingle(Canvas canvas, Size size) {
    final t = clock();
    final engulf = engulfOf();

    final cx = size.width / 2;
    final bottom = size.height; // 불꽃은 바닥에서 솟는다.

    // 각 겹: flicker(scale x/y, rotate, opacity) + engulf 시 확대·가속.
    // 레퍼런스 주기 outer 1.8s / mid 1.2s / core 0.7s. engulf면 짧게.
    _drawLayer(
      canvas,
      cx,
      bottom,
      baseW: engulf ? 260 : 200,
      baseH: engulf ? 320 : 240,
      period: engulf ? 0.6 : 1.8,
      t: t,
      seed: 0.0,
      blur: 8,
      colors: const [
        Color(0x99FF5A1E), // rgba(255,90,30,0.6)
        Color(0x59FF8C3C), // rgba(255,140,60,0.35)
        Color(0x00FF8C3C),
      ],
      stops: const [0.0, 0.35, 0.70],
      baseOpacity: 0.85,
    );
    _drawLayer(
      canvas,
      cx,
      bottom,
      baseW: engulf ? 180 : 130,
      baseH: engulf ? 250 : 200,
      period: engulf ? 0.4 : 1.2,
      t: t,
      seed: 1.7,
      blur: 7,
      colors: const [
        Color(0xE6FFA046), // rgba(255,160,70,0.9)
        Color(0x99FFC864), // rgba(255,200,100,0.6)
        Color(0x00FFC864),
      ],
      stops: const [0.0, 0.40, 0.75],
      baseOpacity: 0.88,
    );
    _drawLayer(
      canvas,
      cx,
      bottom,
      baseW: engulf ? 100 : 70,
      baseH: engulf ? 180 : 140,
      period: engulf ? 0.25 : 0.7,
      t: t,
      seed: 3.1,
      blur: 4,
      colors: const [
        Color(0xFAFFEBB4), // rgba(255,235,180,0.98)
        Color(0xBFFFD28C), // rgba(255,210,140,0.75)
        Color(0x00FFD28C),
      ],
      stops: const [0.0, 0.50, 0.85],
      baseOpacity: 0.92,
    );
  }

  // ── 전폭 불의 벽(burning/done): 종이 폭 전체를 채우는 화력 ────────────────
  // box bottom(= 연소선 burnY 근처)을 베이스로, 가로로 배열된 큰 혀 + 폭 전체
  // 글로우 띠를 3겹(주황 바깥 blur / 노랑 중간 / 흰-노랑 코어)으로 그려 연속된
  // 불의 벽을 만든다. 각 혀는 결정적 sin 조합으로 유기적 flicker(높이/좌우/투명).
  void _paintWall(Canvas canvas, Size size) {
    final t = clock();
    final w = size.width;
    final bottom = size.height; // 벽 베이스(연소선 근처).

    // ── ① 폭 전체 베이스 글로우 띠: 연소선에 깔리는 두꺼운 불의 바닥. ──
    // 살짝 출렁이는 높이로 '활활' 호흡. 좌우로 box 끝까지 가득.
    final bandH = 70 + 14 * sin(t * 4.0);
    final bandRect = Rect.fromLTWH(-4, bottom - bandH, w + 8, bandH + 8);
    final bandPaint = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14)
      ..blendMode = BlendMode.plus
      ..shader = const LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [
          Color(0xCCFF5A1E), // 진한 주황(베이스)
          Color(0x99FF8C3C),
          Color(0x33FFB450),
          Color(0x00FFB450),
        ],
        stops: [0.0, 0.40, 0.75, 1.0],
      ).createShader(bandRect);
    canvas.drawRect(bandRect, bandPaint);

    // ── ② 혀(tongue) 3겹: outer(주황) / mid(노랑) / core(흰-노랑) ──
    // 같은 혀 형상을 폭을 줄여가며 3번 겹쳐 두께감을 준다.
    // outer를 모두 먼저(뒤), 그 다음 mid, 마지막 core(앞).
    _drawTongueLayer(
      canvas,
      w,
      bottom,
      t,
      widthScale: 1.0,
      heightScale: 1.0,
      blur: 10,
      colors: const [
        Color(0xCCFF5A1E),
        Color(0x80FF8C3C),
        Color(0x00FF8C3C),
      ],
      stops: const [0.0, 0.45, 0.85],
    );
    _drawTongueLayer(
      canvas,
      w,
      bottom,
      t,
      widthScale: 0.66,
      heightScale: 0.86,
      blur: 7,
      colors: const [
        Color(0xE6FFA046),
        Color(0x99FFC864),
        Color(0x00FFC864),
      ],
      stops: const [0.0, 0.5, 0.85],
    );
    _drawTongueLayer(
      canvas,
      w,
      bottom,
      t,
      widthScale: 0.40,
      heightScale: 0.66,
      blur: 4,
      colors: const [
        Color(0xFAFFEBB4),
        Color(0xBFFFD28C),
        Color(0x00FFD28C),
      ],
      stops: const [0.0, 0.55, 0.9],
    );
  }

  /// 한 겹(layer)의 혀들을 폭 전체에 가로로 배열해 그린다.
  void _drawTongueLayer(
    Canvas canvas,
    double w,
    double bottom,
    double t, {
    required double widthScale,
    required double heightScale,
    required double blur,
    required List<Color> colors,
    required List<double> stops,
  }) {
    // 혀가 서로 겹치도록 간격보다 넓은 혀 폭(연속된 불의 벽).
    final slot = w / _tongueCount;
    final tongueW = slot * 1.55 * widthScale;

    for (var i = 0; i < _tongueCount; i++) {
      // 슬롯 중앙 + 결정적 좌우 흔들림(sway).
      final baseX = slot * (i + 0.5);
      final sway = sin(t * 3.0 + i * 2.3) * slot * 0.18;
      final cx = baseX + sway;

      // 높이: 결정적 flicker로 min~max 사이 출렁(혀마다 위상 다름).
      final flick = 0.5 + 0.5 * sin(t * (3.4 + (i % 3) * 0.5) + i * 1.9);
      final h =
          (_tongueMinH + (_tongueMaxH - _tongueMinH) * flick) * heightScale;

      // 투명도 일렁임.
      final op = (0.78 + 0.22 * sin(t * 4.2 + i * 1.3)).clamp(0.0, 1.0);
      // 좌우 미세 회전(혀 끝이 살랑).
      final rot = 0.12 * sin(t * 2.6 + i * 1.1);

      final rect = Rect.fromCenter(
        center: Offset(cx, bottom - h / 2),
        width: tongueW,
        height: h,
      );
      final paint = Paint()
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur)
        ..blendMode = BlendMode.plus
        ..shader = RadialGradient(
          center: const Alignment(0, 0.7),
          radius: 0.95,
          colors: colors
              .map((c) => c.withValues(alpha: c.a * op))
              .toList(growable: false),
          stops: stops,
        ).createShader(rect);

      canvas.save();
      canvas.translate(cx, bottom);
      canvas.rotate(rot);
      canvas.translate(-cx, -bottom);
      canvas.drawPath(_flamePath(cx, bottom, tongueW, h), paint);
      canvas.restore();
    }
  }

  void _drawLayer(
    Canvas canvas,
    double cx,
    double bottom, {
    required double baseW,
    required double baseH,
    required double period,
    required double t,
    required double seed,
    required double blur,
    required List<Color> colors,
    required List<double> stops,
    required double baseOpacity,
  }) {
    // flicker: 주기적 scale/opacity 변동(결정적 sin).
    final ph = (t / period) * 2 * pi + seed;
    final sx = 1.0 + 0.07 * sin(ph);
    final sy = 1.0 + 0.12 * sin(ph * 1.15 + 0.6);
    final rot = 0.035 * sin(ph * 0.8 + seed); // ±~2deg
    final op = (baseOpacity + 0.12 * sin(ph * 1.3)).clamp(0.0, 1.0);

    final w = baseW * sx;
    final h = baseH * sy;

    // 불꽃 형태: 위가 뾰족하고 아래가 둥근 물방울 역상.
    // 타원 + 위로 갈수록 좁아지는 path로 근사. RadialGradient(center bottom).
    final rect = Rect.fromCenter(
      center: Offset(cx, bottom - h / 2),
      width: w,
      height: h,
    );

    final paint = Paint()
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur)
      ..blendMode = BlendMode.plus // screen 근사(가산 합성).
      ..shader = RadialGradient(
        center: const Alignment(0, 0.6), // center bottom 쪽.
        radius: 0.85,
        colors: colors
            .map((c) => c.withValues(alpha: c.a * op))
            .toList(growable: false),
        stops: stops,
      ).createShader(rect);

    canvas.save();
    canvas.translate(cx, bottom);
    canvas.rotate(rot);
    canvas.translate(-cx, -bottom);
    // 물방울(불꽃) path: 바닥은 넓고 둥글게, 위로 좁아지며 끝이 뾰족.
    final path = _flamePath(cx, bottom, w, h);
    canvas.drawPath(path, paint);
    canvas.restore();
  }

  /// 불꽃 윤곽: 바닥 중앙에서 좌우로 벌어졌다 위로 모여 뾰족해지는 닫힌 베지어.
  Path _flamePath(double cx, double bottom, double w, double h) {
    final halfW = w / 2;
    final tip = Offset(cx, bottom - h); // 꼭짓점(위).
    final baseL = Offset(cx - halfW * 0.85, bottom);
    final baseR = Offset(cx + halfW * 0.85, bottom);
    final bellyL = Offset(cx - halfW, bottom - h * 0.45);
    final bellyR = Offset(cx + halfW, bottom - h * 0.45);

    return Path()
      ..moveTo(baseL.dx, baseL.dy)
      // 왼쪽 배 → 꼭짓점.
      ..quadraticBezierTo(bellyL.dx, bellyL.dy, tip.dx, tip.dy)
      // 꼭짓점 → 오른쪽 배.
      ..quadraticBezierTo(bellyR.dx, bellyR.dy, baseR.dx, baseR.dy)
      // 바닥(둥글게).
      ..quadraticBezierTo(cx, bottom + h * 0.06, baseL.dx, baseL.dy)
      ..close();
  }

  @override
  bool shouldRepaint(covariant FlamePainter old) => true; // clock 매 프레임 변동.
}

// ════════════════════════════════════════════════════════════════════════
// 상향 화살표 힌트(bobbing) — 레퍼런스 .drag-arrow.
// ════════════════════════════════════════════════════════════════════════
class _BobbingArrow extends StatelessWidget {
  const _BobbingArrow({required this.clock});
  final double clock;

  @override
  Widget build(BuildContext context) {
    // arrow-bob 1.4s: 위로 -10px, opacity 0.45↔0.85.
    final ph = (clock / 1.4) * 2 * pi;
    final dy = -(sin(ph).clamp(0.0, 1.0)) * 10;
    final op = 0.45 + 0.4 * (sin(ph).clamp(0.0, 1.0));
    return Transform.translate(
      offset: Offset(0, dy),
      child: Opacity(
        opacity: op,
        child: CustomPaint(
          size: const Size(28, 40),
          painter: _ArrowPainter(),
        ),
      ),
    );
  }
}

class _ArrowPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xE6FFC8AA) // rgba(255,200,170,0.9)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // M14 4 L14 36 (세로) / M4 14 L14 4 L24 14 (화살촉).
    canvas.drawLine(const Offset(14, 4), const Offset(14, 36), paint);
    final head = Path()
      ..moveTo(4, 14)
      ..lineTo(14, 4)
      ..lineTo(24, 14);
    canvas.drawPath(head, paint);
  }

  @override
  bool shouldRepaint(covariant _ArrowPainter old) => false;
}
