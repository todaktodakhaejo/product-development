import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:sensors_plus/sensors_plus.dart';

import '../../core/haptics.dart';
import '../../core/strings.dart';
import '../../theme/app_theme.dart';
import '../writing/writing_screen.dart';
import 'emotion_ball.dart';
import 'emotion_ball_painter.dart';

/// 2단계 첫 화면(홈). 감정 오브제(공)와 4종 제스처 인터랙션의 무대.
///
///  - GST-01 흔들기 : 선형 가속도 임펄스(쿨다운만으로 연속 발동) + medium/heavy 햅틱
///  - GST-02 굴리기 : 손가락 드래그 추종 + 이동거리 기반 마찰 틱 → 놓으면 관성 fling(부스트)
///  - GST-03 누르기 : 본체 홀드 → 누르는 동안 점점 침몰(pressStart/End) + 햅틱(down/tick/release)
///  - GST-04 쓰다듬기: 제자리 왕복 드래그 → 표면 출렁임 + 글로우 + 연속 약진동(strokeSoft)
///
/// 굴리기·쓰다듬기는 둘 다 단일 포인터 드래그라, **손가락 속도**를 1차 판별자로
/// 쓰는 상태머신(none→stroke|roll)으로 모드를 판별한다([_onPointerMove] 참고, v6).
/// 느리면 stroke(공 제자리), 빠르거나(speed>kRollSpeed) 멀리(net>r*kRollNet) 끌면 roll.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

/// 단일 포인터 드래그의 자동 판별 모드(v6, 속도 기반).
/// none → (stroke | roll). roll은 sticky(포인터 업까지 고정), stroke는 매 프레임
/// 재평가되어 빨라지면 roll로 탈출한다(pending 제거).
enum _DragMode { none, stroke, roll }

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<int> _frame = ValueNotifier(0);

  EmotionBall? _ball;
  final List<Ripple> _ripples = [];

  // 센서: 흔들기(GST-01)용 선형 가속도(중력 제거) 1개만 구독.
  StreamSubscription? _accelSub;
  // armed 게이트 제거(§1): 연속 흔들기에서 가속도가 임계 아래로 안 떨어져
  // 재발동이 막히던 문제 → 쿨다운(90ms)만으로 게이팅한다.
  DateTime _lastShake = DateTime.fromMillisecondsSinceEpoch(0);

  // 흔들기 임펄스 방향용 난수(State 당 1개만 보유).
  final Random _rng = Random();

  // 포인터 상태 (누르기 / 굴리기 / 쓰다듬기 통합)
  int? _pointerId;
  Offset _downPos = Offset.zero;
  Offset _lastPos = Offset.zero;
  Duration _lastMoveTime = Duration.zero;
  Offset _flingVel = Offset.zero;
  // EMA 첫 유효샘플 판별(v5 §1): 포인터 다운마다 false로 리셋. 첫 샘플은 그대로
  // 채택하고 이후부터 지수이동평균으로 다듬어 release 직전 단일 이벤트의 폭주/미약을 방지.
  bool _flingSeeded = false;
  bool _moved = false;

  // 드래그 판별 상태머신(v6 §2, 속도 기반)
  _DragMode _dragMode = _DragMode.none;
  double _strokeEnergy = 0; // 쓰다듬기 누적(0~1) → wobble/글로우 구동
  double _rollAccum = 0; // 굴리기 누적 이동거리(px) → 마찰 틱 발사 타이밍
  // stroke→roll 늦은 전환 시 공이 손가락과 벌어져 있어 ease 추종으로 따라잡는
  // 프레임 카운터(v6 §2). 0이면 full grab.
  int _rollCatchup = 0;

  // 손가락 속도 추적(v6 §1) — 판별 1차 기준. fling용 _flingVel과는 별개.
  double _dragSpeed = 0; // 평활된 손가락 속도(px/s)
  bool _dragSpeedSeeded = false; // 첫 유효샘플 채택 플래그

  bool _showComfort = true;
  late final String _comfort = randomComfortMessage();

  Duration _lastTick = Duration.zero;

  static const double _slop = 14;

  // 흔들기(GST-01) 선형 가속도 임계(m/s², §1 강화). userAccelerometer는 중력이
  // 제거돼 정지 시 ≈0, 직선으로 흔들면 즉시 큰 값이 잡힌다. 임계를 낮춰(9) 쉽게
  // 발동하고, 상한을 26으로 당겨 강도가 빨리 포화된다.
  static const double kShakeOn = 9.0; // 발동 임계(12→9)
  static const double kShakeMax = 26.0; // 정규화 상한(32→26)
  static const Duration _shakeCooldown = Duration(milliseconds: 90); // 140→90

  // 드래그 판별 임계(v6 §2 — 속도 기반). 거리·방향전환 기반 상수는 폐기.
  static const double kRollSpeed = 900; // px/s, 손가락 속도가 이를 넘으면 굴리기(§1 완화: 420→900)
  static const double kRollNet = 1.2; // ×radius, 느려도 이만큼 끌면 굴리기
  // 손가락 속도 EMA/clamp 상수(v6 §1).
  static const double kDragMinDt = 0.004; // 이보다 짧은 dt 샘플은 속도 계산서 제외
  static const double kDragSpeedClamp = 4000; // 순간속도 magnitude 상한(px/s)
  static const int kRollCatchupFrames = 6; // stroke→roll 늦은 전환 시 따라잡기 프레임

  // 굴리기 fling 평활/clamp 상수(v5 §1).
  static const double kFlingMinDt = 0.004; // 이보다 짧은 dt 샘플은 속도 계산서 제외
  static const double kFlingSpikeClamp = 3000; // 순간속도 magnitude 스파이크 컷(px/s)
  static const double kFlingReleaseClamp =
      3200; // release 시 최종 속도 크기 상한(px/s, §3: 2400→3200 동적범위↑)

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    _listenSensors();
  }

  void _listenSensors() {
    // 흔들기(GST-01): 선형 가속도(중력 제거, m/s²). v2의 자이로는 회전 각속도라
    // 직선 흔들기에 거의 안 잡혀 먹통이었음 → 가속도로 교체(§1). 미지원 기기/웹
    // 에서는 onError로 무시되어 흔들기만 비활성화되고 터치 제스처는 정상 동작한다.
    _accelSub = userAccelerometerEventStream().listen(
      (e) {
        final mag = sqrt(e.x * e.x + e.y * e.y + e.z * e.z); // 가속도 크기(m/s²)
        // 발동 조건(§1): 임계 이상 + 쿨다운 경과. armed 게이트를 없애 연속으로
        // 흔들면 90ms마다 계속 임펄스가 쌓여 공이 통통 튀고 벽에 부딪힌다.
        if (mag < kShakeOn) return;
        final now = DateTime.now();
        if (now.difference(_lastShake) < _shakeCooldown) return;
        _lastShake = now;

        // 임펄스 강도(§2): 세기 범위를 넓혀 "흔드는 맛". 하한을 0.4로 낮춰
        // 살살 흔들면 작게(0.4), 세게는 1.0까지 대비가 커진다.
        final strength =
            ((mag - kShakeOn) / (kShakeMax - kShakeOn)).clamp(0.0, 1.0);
        // 방향(§2): 랜덤 단위벡터 폐기 → 흔든 가속도 벡터를 화면 방향으로 추종.
        // 포트레이트 기준 x=화면 가로, y는 부호 반전해 화면 세로로 매핑한다.
        final accel = Offset(e.x, -e.y);
        final aLen = accel.distance;
        // 가속도가 사실상 0이면(정지/노이즈) 난수로 폴백, 아니면 정규화한 방향.
        final base = aLen > 0.001 ? accel / aLen : _randomUnitVector();
        // 생동감 위해 22%만 난수를 섞어 매 흔들기를 미세하게 다르게 한다.
        final dir = base * 0.78 + _randomUnitVector() * 0.22;
        final d = dir.distance;
        final unit = d > 0.001 ? dir / d : base; // 재정규화(0이면 base 폴백)
        _ball?.addImpulse(unit, max(0.4, strength));
        // 진동 강화(§1): light 폐기. 게이트 통과한 흔들기는 항상 묵직하게 —
        // mag<13 → medium, mag>=13 → heavy. 매 발동마다 느껴지게 throttle:false.
        final level = mag < 13 ? HapticLevel.medium : HapticLevel.heavy;
        Haptics.instance.fire(level, throttle: false);
        if (_showComfort) setState(() => _showComfort = false);
      },
      onError: (_) {}, // 센서 미지원 기기에서도 터치는 동작
      cancelOnError: false,
    );
  }

  /// 흔들기 임펄스용 랜덤 단위벡터(사방으로 튀는 손맛).
  Offset _randomUnitVector() {
    final a = _rng.nextDouble() * 2 * pi;
    return Offset(cos(a), sin(a));
  }

  void _onTick(Duration elapsed) {
    final dt = _lastTick == Duration.zero
        ? 0.016
        : (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    final ball = _ball;
    if (ball == null) return;
    final clampedDt = dt.clamp(0.0, 0.05);

    // 쓰다듬기 에너지 시간 감쇠(v5 §2): *0.7→*0.5로 더 천천히 사그라들게 해
    // 쓰다듬는 동안 빛이 누적·유지되도록 한다(증가율·상한 1.0은 그대로). stroke 중엔 move에서 증가.
    _strokeEnergy = (_strokeEnergy - clampedDt * 0.5).clamp(0.0, 1.0);

    ball.update(clampedDt, Offset.zero); // 중력 굴리기 폐기 → gravity 0

    // 벽 충돌 햅틱
    if (ball.lastImpact > 0) {
      Haptics.instance.impactByStrength(ball.lastImpact);
    }

    // 누르기 홀드 중 미세 틱(§2): 침몰 깊이가 깊어지는 정점(0.5·0.85 통과)을 ball이
    // 물리에서 단일 소스로 내보낸다. 프레임당 1회만 소비해 미세 틱 햅틱을 발사 →
    // 시각 침몰과 햅틱이 desync 없이 동기. (시작 pressDown·뗄 때 pressRelease는 포인터에서.)
    if (ball.consumePressHoldTick()) {
      Haptics.instance.pressHoldTick();
    }

    for (final r in _ripples) {
      r.update(clampedDt);
    }
    _ripples.removeWhere((r) => r.dead);

    _frame.value++;
  }

  // ── 포인터(터치) 처리 ───────────────────────────────────────────
  void _onPointerDown(PointerDownEvent e) {
    if (_pointerId != null) return;
    final ball = _ball;
    if (ball == null) return;
    final pos = e.localPosition;
    _pointerId = e.pointer;
    _downPos = _lastPos = pos;
    _lastMoveTime = e.timeStamp;
    _moved = false;
    // fling 속도 평활 리셋(v5 §1): 새 드래그마다 속도/첫샘플 플래그 초기화.
    _flingVel = Offset.zero;
    _flingSeeded = false;
    // 드래그 메트릭 초기화(v6)
    _dragMode = _DragMode.none;
    _rollAccum = 0; // 굴리기 마찰 누적 리셋
    _rollCatchup = 0;
    // 손가락 속도 추적 리셋(v6 §1): 다운마다 0/false. fling용과 별개.
    _dragSpeed = 0;
    _dragSpeedSeeded = false;

    // 누르기 홀드(GST-03, §2): 본체 위에서 누르기 시작 → 누르는 동안 침몰.
    // 이동(slop 초과)이 시작되면 _onPointerMove에서 pressEnd로 전환된다.
    // 본체 밖이면 누르기 침몰 없이(Ripple은 떼는 순간 onPointerUp에서) 진행.
    if (ball.hitTest(pos)) {
      ball.pressStart(pos);
      Haptics.instance.pressDown();
    }
    if (_showComfort) setState(() => _showComfort = false); // HOME-04
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (e.pointer != _pointerId) return;
    final ball = _ball;
    if (ball == null) return;
    final pos = e.localPosition;
    final step = pos - _lastPos;
    final stepLen = step.distance;

    // 손가락 속도 추적(v6 §1): 판별의 1차 기준. dt가 너무 짧으면(<4ms) 순간속도가
    // 과대평가되므로 속도 갱신은 건너뛴다(_lastPos·시간은 아래에서 항상 갱신).
    final moveDt = (e.timeStamp - _lastMoveTime).inMicroseconds / 1e6;
    if (moveDt >= kDragMinDt) {
      var instant = stepLen / moveDt; // 순간 손가락 속도(px/s)
      if (instant > kDragSpeedClamp) instant = kDragSpeedClamp;
      _dragSpeed = _dragSpeedSeeded
          ? _dragSpeed * 0.6 + instant * 0.4 // 이후 EMA(0.6:0.4)
          : instant; // 첫 유효샘플은 그대로 채택
      _dragSpeedSeeded = true;
    }

    if (!_moved && (pos - _downPos).distance > _slop) {
      _moved = true;
      // 누르기 → 드래그 전환(v6 §3): 침몰을 팝 없이 즉시 취소(pressEnd의 elastic
      // 복원 팝이 쓰다듬기 시작에서 "꿀렁"으로 오인되던 문제 제거).
      ball.pressCancel();
      // 모드 미확정(none)으로 두고 곧바로 아래 속도 평가에서 stroke/roll 결정한다
      // ('잠정 roll/pending로 시작' 제거).
      _dragMode = _DragMode.none;
    }

    if (_moved) {
      final net = (pos - _downPos).distance;
      final r = ball.radius;

      // 판별(v6 §2): roll은 sticky, stroke는 매 프레임 재평가.
      if (_dragMode != _DragMode.roll &&
          (_dragSpeed > kRollSpeed || net > r * kRollNet)) {
        // ROLL 진입(sticky): 빠르거나 멀리 끌었다 = 명백한 굴리기.
        final wasStroke = _dragMode == _DragMode.stroke;
        _dragMode = _DragMode.roll;
        ball.pressCancel(); // 혹시 남은 침몰 무팝 제거
        Haptics.instance.fire(HapticLevel.light); // roll 첫 진입 알림 1회
        // stroke에서 늦게 전환됐으면 공이 손가락과 벌어져 있으므로 ease 추종으로
        // 몇 프레임 따라잡는다(처음부터 빠른 굴리기는 gap이 거의 없어 불필요).
        if (wasStroke) _rollCatchup = kRollCatchupFrames;
      } else if (_dragMode != _DragMode.roll) {
        // STROKE: 느리고 국소. 공은 제자리, 표면만 출렁이고 빛이 차오른다.
        _dragMode = _DragMode.stroke;
        ball.stroke(step); // 제자리 고정 출렁임(공 이동 없음)
        _strokeEnergy =
            (_strokeEnergy + stepLen / r * 0.4).clamp(0.0, 1.0); // step 비례 증가
        // 위로받는 부드러운 저강도 텍스처를 흐르듯 발사(throttle은 strokeSoft 내장).
        Haptics.instance.strokeSoft();
      }

      // ROLL 거동: catchup 중엔 ease 추종으로 gap을 좁히고, 이후 full 추종.
      if (_dragMode == _DragMode.roll) {
        if (_rollCatchup > 0) {
          ball.grab(pos, ease: 0.4);
          _rollCatchup--;
        } else {
          ball.grab(pos); // 손가락 1:1 추종(full)
        }
        // 굴리기 마찰감: 이동 누적이 반경의 절반을 넘을 때마다 마찰 틱 발사 →
        // 구슬 굴리는 자글거림. speed01은 추종 속도(px/s)를 2600으로 정규화.
        _rollAccum += stepLen;
        final tickDist = r * 0.5;
        if (_rollAccum >= tickDist) {
          _rollAccum -= tickDist;
          final speed01 =
              (moveDt > 0 ? (stepLen / moveDt) / 2600 : 0.0).clamp(0.0, 1.0);
          Haptics.instance.rollFriction(speed01);
        }
      }
    }

    // 플링 속도 추정(v5 §1): 매 이벤트 순간속도를 그대로 덮어쓰던 v4를 EMA 평활로 교체.
    // 너무 짧은 dt(<4ms) 샘플은 순간속도가 과대평가되므로 속도 계산에서 제외하되,
    // _lastPos·_lastMoveTime은 항상 갱신해 다음 샘플의 dt/변위가 정확하도록 한다.
    // dt는 위 손가락 속도 추적과 동일하므로 moveDt를 재사용(_flingVel은 별개 평활).
    if (moveDt >= kFlingMinDt) {
      var instant = (pos - _lastPos) / moveDt; // 순간속도(px/s)
      // 스파이크 컷: 비정상적으로 큰 순간속도는 크기를 3000px/s로 제한.
      final m = instant.distance;
      if (m > kFlingSpikeClamp) instant = instant / m * kFlingSpikeClamp;
      // 첫 유효샘플은 그대로 채택, 이후는 EMA(0.5:0.5)로 다듬어 폭주/미약 둘 다 억제.
      _flingVel = _flingSeeded ? _flingVel * 0.5 + instant * 0.5 : instant;
      _flingSeeded = true;
    }
    _lastPos = pos;
    _lastMoveTime = e.timeStamp;
  }

  void _onPointerUp(PointerUpEvent e) {
    if (e.pointer != _pointerId) return;
    final ball = _ball;
    _pointerId = null;

    if (ball == null) return;
    if (!_moved) {
      // 누르기 홀드 종료(GST-03, §2): 드래그로 전환되지 않고 제자리에서 손을 뗌.
      // pressStart는 _onPointerDown(본체 위)에서 이미 걸렸으므로 여기서 복원 시작 +
      // 떼는 톡(pressRelease) 발사. 짧게 톡 친 탭도 같은 경로(얕게 들어갔다 톡).
      // 물결은 항상(본체 안팎 무관). 본체 밖 탭은 pressStart가 없었으니 pressEnd는
      // 무해(holding=false) — 물결만 남는다.
      final pos = e.localPosition;
      _ripples.add(Ripple(pos));
      if (ball.hitTest(_downPos)) {
        ball.pressEnd();
        Haptics.instance.pressRelease();
      }
    } else if (_dragMode == _DragMode.roll) {
      // fling 일관화(v5 §1): v4의 *1.5 부스트 제거. EMA로 다듬은 속도를 [0,2400]px/s로
      // clamp만 해 어느 방향이든 비슷한 사거리로 미끄러지게 한다(폭주·답답함 동시 해소).
      ball.release();
      var v = _flingVel;
      if (v.distance > kFlingReleaseClamp) {
        v = v / v.distance * kFlingReleaseClamp;
      }
      ball.vel = v; // 던진 손맛(관성 fling), 크기만 상한 적용
    } else {
      // stroke / none(미커밋): grabbed 해제만, vel 부여 안 함(날아가지 않음, v6 §2).
      ball.release();
    }
    _moved = false;
    _dragMode = _DragMode.none;
  }

  void _goToWriting() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const WritingScreen()),
    );
  }

  @override
  void dispose() {
    _ticker.dispose();
    _accelSub?.cancel();
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final rect = Offset.zero &
                  Size(constraints.maxWidth, constraints.maxHeight);
              if (_ball == null) {
                _ball = EmotionBall(bounds: rect);
              } else {
                _ball!.resize(rect);
              }
              return Stack(
                children: [
                  // 공 + 물결 캔버스 + 포인터
                  Positioned.fill(
                    child: Listener(
                      onPointerDown: _onPointerDown,
                      onPointerMove: _onPointerMove,
                      onPointerUp: _onPointerUp,
                      behavior: HitTestBehavior.opaque,
                      child: CustomPaint(
                        painter: EmotionBallPainter(
                          ball: _ball!,
                          ripples: _ripples,
                          strokeEnergy: _strokeEnergy,
                          repaint: _frame,
                        ),
                      ),
                    ),
                  ),

                  // HOME-03 위로 멘트 (만지면 사라짐)
                  Positioned(
                    top: 28,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: _showComfort ? 1 : 0,
                        duration: const Duration(milliseconds: 600),
                        child: Text(
                          _comfort,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 18,
                            color: Colors.white70,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ),
                  ),

                  // 글쓰기 진입 단일 경로 (HOME-05). 자동 강제 전환 없음.
                  Positioned(
                    bottom: 24,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: TextButton.icon(
                        onPressed: _goToWriting,
                        icon: const Icon(Icons.edit_note, size: 18),
                        label: const Text('바로 글쓰기'),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white60,
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
