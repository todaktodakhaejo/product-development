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
/// 굴리기·쓰다듬기는 둘 다 단일 포인터 드래그라, net 이동거리 기반 sticky
/// 상태머신(none→pending→roll|stroke)으로 모드를 판별한다([_onPointerMove] 참고).
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

/// 단일 포인터 드래그의 자동 판별 모드.
/// none → pending → (roll | stroke). roll/stroke 커밋되면 포인터 업까지 고정(sticky).
enum _DragMode { none, pending, roll, stroke }

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

  // 드래그 판별 상태머신(§4.2 / §6.2)
  _DragMode _dragMode = _DragMode.none;
  double _pathLen = 0; // 누적 경로 길이(px)
  int _turnCount = 0; // 방향 전환 횟수
  Offset _lastMoveDir = Offset.zero;
  double _strokeEnergy = 0; // 쓰다듬기 누적(0~1) → wobble/글로우 구동
  double _rollAccum = 0; // 굴리기 누적 이동거리(px) → 마찰 틱 발사 타이밍

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

  // 드래그 판별 임계(§3 — net 이동거리 기반 + sticky)
  static const double kTurnDot = -0.1; // 방향전환 인정 내적(약 95°)
  static const double kMinStep = 2.0; // px, 노이즈 컷
  static const double kRollNet = 0.9; // net > radius * 0.9 → roll 커밋
  // 쓰다듬기 커밋 완화·조기화(v5 §2): 한 번만 왕복해도, 제자리 근처에서 짧게라도
  // 비비면 곧장 stroke로 넘어가 "쓰다듬는다"는 인지를 빨리 준다(v4 0.6/2.5/2에서 완화).
  static const double kStrokeNet = 0.7; // net < radius * 0.7 (제자리 근처, 완화)
  static const double kStrokePath = 1.2; // pathLen > radius * 1.2 (왕복 문턱 낮춤)
  static const int kStrokeTurns = 1; // 방향전환 1회 이상 → stroke 커밋

  // 굴리기 fling 평활/clamp 상수(v5 §1).
  static const double kFlingMinDt = 0.004; // 이보다 짧은 dt 샘플은 속도 계산서 제외
  static const double kFlingSpikeClamp = 3000; // 순간속도 magnitude 스파이크 컷(px/s)
  static const double kFlingReleaseClamp = 2400; // release 시 최종 속도 크기 상한(px/s)

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

        // 임펄스 강도: 약하게 흔들어도 공이 벽까지 튀도록 하한 0.6 보장(§1).
        final strength =
            ((mag - kShakeOn) / (kShakeMax - kShakeOn)).clamp(0.0, 1.0);
        _ball?.addImpulse(_randomUnitVector(), max(0.6, strength));
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
    // 드래그 메트릭 초기화
    _dragMode = _DragMode.none;
    _pathLen = 0;
    _turnCount = 0;
    _lastMoveDir = Offset.zero;
    _rollAccum = 0; // 굴리기 마찰 누적 리셋

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

    if (!_moved && (pos - _downPos).distance > _slop) {
      _moved = true;
      // 누르기 → 드래그 전환(§3): 홀드 침몰을 즉시 복원 시작. 손을 뗀 게 아니라
      // 끌기로 바뀐 것이므로 pressRelease 햅틱은 생략(pressDown만 이미 울렸음).
      ball.pressEnd();
      // pending으로 시작(§3): 아직 roll/stroke 미확정. 공은 살짝만 추종해
      // 쓰다듬기로 커밋돼도 거의 제자리에 남는다.(기존 '잠정 roll' 제거)
      _dragMode = _DragMode.pending;
    }

    if (_moved) {
      // 드래그 메트릭 누적(§3): net=시작점 기준 직선거리, pathLen=누적 경로,
      // turnCount=방향전환 횟수(기존 방식 유지).
      _pathLen += stepLen;
      if (stepLen > kMinStep) {
        final stepDir = step / stepLen;
        if (_lastMoveDir != Offset.zero &&
            _lastMoveDir.dx * stepDir.dx + _lastMoveDir.dy * stepDir.dy <
                kTurnDot) {
          _turnCount++; // ~95° 이상 꺾임 = 방향 전환
        }
        _lastMoveDir = stepDir;
      }
      final net = (pos - _downPos).distance;
      final r = ball.radius;

      // sticky 커밋 판정(§3): pending일 때만 평가하고, roll/stroke로 한 번
      // 커밋되면 포인터 업까지 모드 변경 금지(굴리기↔쓰다듬기 오판/혼선 방지).
      if (_dragMode == _DragMode.pending) {
        if (net > r * kRollNet) {
          // ROLL 커밋: 공을 시작점에서 거의 반경만큼 끌고 감 = 명백히 끌기.
          // 곡선으로 이리저리 끌어도 이후 계속 roll 유지.
          _dragMode = _DragMode.roll;
          Haptics.instance.fire(HapticLevel.light); // roll 진입 알림 1회
        } else if (_turnCount >= kStrokeTurns &&
            net < r * kStrokeNet &&
            _pathLen > r * kStrokePath) {
          // STROKE 커밋: 제자리 근처(net 작음)에서 충분히 왕복(path 길고 전환 잦음).
          _dragMode = _DragMode.stroke;
        }
      }

      // 모드별 동작
      if (_dragMode == _DragMode.stroke) {
        ball.stroke(step); // 제자리 고정 출렁임(공 이동 없음)
        _strokeEnergy = (_strokeEnergy + stepLen / r * 0.4)
            .clamp(0.0, 1.0); // step 비례 증가
        // 쓰다듬기 힐링(요구2): 위로받는 부드러운 저강도 텍스처를 흐르듯 발사
        // (throttle은 strokeSoft 내장).
        Haptics.instance.strokeSoft();
      } else if (_dragMode == _DragMode.roll) {
        ball.grab(pos); // 손가락 1:1 추종(full)
        // 굴리기 마찰감(§3): 이동 누적이 반경의 절반을 넘을 때마다 마찰 틱 발사
        // → 구슬 굴리는 자글거림. 손가락이 빠를수록 잦고 강하다. speed01은 추종
        // 속도(px/s)를 2600으로 정규화. throttle은 rollFriction 내장.
        _rollAccum += stepLen;
        final tickDist = r * 0.5;
        if (_rollAccum >= tickDist) {
          _rollAccum -= tickDist;
          final moveDt = (e.timeStamp - _lastMoveTime).inMicroseconds / 1e6;
          final speed01 =
              (moveDt > 0 ? (stepLen / moveDt) / 2600 : 0.0).clamp(0.0, 1.0);
          Haptics.instance.rollFriction(speed01);
        }
      } else {
        // pending(v5 §2): 추종 더 약화(ease 0.2). 커밋 전 공이 거의 제자리에 머물러
        // 쓰다듬기로 넘어가도 "한 번 꿀렁" 대신 제자리 출렁임으로 자연히 이어진다.
        ball.grab(pos, ease: 0.2);
      }
    }

    // 플링 속도 추정(v5 §1): 매 이벤트 순간속도를 그대로 덮어쓰던 v4를 EMA 평활로 교체.
    // 너무 짧은 dt(<4ms) 샘플은 순간속도가 과대평가되므로 속도 계산에서 제외하되,
    // _lastPos·_lastMoveTime은 항상 갱신해 다음 샘플의 dt/변위가 정확하도록 한다.
    final dtMove = (e.timeStamp - _lastMoveTime).inMicroseconds / 1e6;
    if (dtMove >= kFlingMinDt) {
      var instant = (pos - _lastPos) / dtMove; // 순간속도(px/s)
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
      // stroke / pending(미커밋): grabbed 해제만, vel 부여 안 함(날아가지 않음).
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
