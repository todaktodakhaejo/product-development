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
///  - GST-01 흔들기 : 선형 가속도 3구간(약/중/강) 임펄스 + light/medium/heavy 햅틱
///  - GST-02 굴리기 : 손가락 드래그 추종 + 이동거리 기반 마찰 틱 → 놓으면 관성 fling
///  - GST-03 누르기 : 본체 홀드 → 누르는 동안 점점 침몰(pressStart/End) + 햅틱(down/tick/release)
///  - GST-04 쓰다듬기: 제자리 왕복 드래그 → 표면 출렁임 + 글로우 + 연속 약진동(strokeSoft)
///
/// 굴리기·쓰다듬기는 둘 다 단일 포인터 드래그라, 드래그 메트릭(직진성·방향전환)
/// 으로 모드를 자동 판별한다(히스테리시스, [_onPointerMove] 참고).
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

/// 단일 포인터 드래그의 자동 판별 모드.
enum _DragMode { none, roll, stroke }

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<int> _frame = ValueNotifier(0);

  EmotionBall? _ball;
  final List<Ripple> _ripples = [];

  // 센서: 흔들기(GST-01)용 선형 가속도(중력 제거) 1개만 구독.
  StreamSubscription? _accelSub;
  bool _shakeArmed = true; // 재발동 게이트(연속 폭주 방지)
  DateTime _lastShake = DateTime.fromMillisecondsSinceEpoch(0);

  // 흔들기 임펄스 방향용 난수(State 당 1개만 보유).
  final Random _rng = Random();

  // 포인터 상태 (누르기 / 굴리기 / 쓰다듬기 통합)
  int? _pointerId;
  Offset _downPos = Offset.zero;
  Offset _lastPos = Offset.zero;
  Duration _lastMoveTime = Duration.zero;
  Offset _flingVel = Offset.zero;
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

  // 흔들기(GST-01) 선형 가속도 임계(m/s²). userAccelerometer는 중력이 제거돼
  // 정지 시 ≈0, 직선으로 흔들면 즉시 큰 값이 잡힌다(자이로와 달리 비틀 필요 없음).
  static const double kShakeOn = 12.0; // 발동 임계
  static const double kShakeOff = 6.0; // 해제(재발동 허용) 임계
  static const double kShakeMax = 32.0; // 정규화 상한
  static const Duration _shakeCooldown = Duration(milliseconds: 140);

  // 드래그 판별 임계(§4 — stroke 관대화, roll 약간 상향)
  static const double kTurnDot = -0.1; // 방향전환 인정 내적(약 95°)
  static const double kStrokeStraight = 0.55; // 미만 + 1회 이상 전환 → stroke
  static const double kRollStraight = 0.72; // 초과 + 큰 net → roll
  static const double kRollNetFactor = 0.8; // net > radius * 0.8
  static const int kStrokeTurns = 1; // 전환 횟수 임계(완화: 2→1)
  static const double kMinStep = 2.0; // px, 노이즈 컷
  static const double kStrokeNetFactor = 0.5; // net < path*0.5 → 제자리 맴돔

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
        if (mag < kShakeOff) {
          _shakeArmed = true; // 충분히 잦아들면 다음 흔들기 허용
          return;
        }
        if (mag < kShakeOn || !_shakeArmed) return;
        // 쿨다운(연속 발사 폭주 방지)
        final now = DateTime.now();
        if (now.difference(_lastShake) < _shakeCooldown) return;
        _lastShake = now;
        _shakeArmed = false;

        // 임펄스 강도: 약하게 흔들어도 공이 눈에 띄게 튀도록 하한 0.35 보장(§1).
        final strength =
            ((mag - kShakeOn) / (kShakeMax - kShakeOn)).clamp(0.0, 1.0);
        _ball?.addImpulse(_randomUnitVector(), max(0.35, strength));
        // 흔들기 강도 체감(§1): 가속도 mag를 직접 3구간(약/중/강)으로 나눠
        // light/medium/heavy를 명시 발사 → 세게 흔들수록 손에 단차가 확연.
        // 게이트를 통과한 흔들기는 매번 손에 느껴져야 하므로 throttle:false.
        final HapticLevel level;
        if (mag < 19) {
          level = HapticLevel.light; // 약 (12~19 m/s²)
        } else if (mag < 26) {
          level = HapticLevel.medium; // 중 (19~26 m/s²)
        } else {
          level = HapticLevel.heavy; // 강 (26+ m/s²)
        }
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

    // 쓰다듬기 에너지 시간 감쇠(멈추면 ~1.5s 내 잦아듦). stroke 중엔 move에서 증가.
    _strokeEnergy = (_strokeEnergy - clampedDt * 0.7).clamp(0.0, 1.0);

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
      // 누르기 → 드래그 전환(§2): 홀드 침몰을 즉시 복원 시작. 손을 뗀 게 아니라
      // 끌기로 바뀐 것이므로 pressRelease 햅틱은 생략(pressDown만 이미 울렸음).
      ball.pressEnd();
      // 잠정 roll로 시작(공이 손가락을 따라오는 즉각 반응이 직관적).
      _dragMode = _DragMode.roll;
      Haptics.instance.fire(HapticLevel.light); // 굴리기 모드 진입 알림 1회
    }

    if (_moved) {
      // 드래그 메트릭 누적
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
      final straightness = net / max(_pathLen, 1);

      // 히스테리시스 판정(§4): 데드존(0.55~0.72)으로 모드 떨림 방지하되 stroke를
      // 관대하게. stroke 진입 = (꺾임이 있고 직진성 낮음) 또는 (제자리 맴돔:
      // net이 경로 길이의 절반 미만). roll 진입은 직진성·net 문턱을 약간 상향.
      final inPlace = net < _pathLen * kStrokeNetFactor && _pathLen > _slop;
      if (_dragMode != _DragMode.stroke &&
          ((straightness < kStrokeStraight && _turnCount >= kStrokeTurns) ||
              inPlace)) {
        _dragMode = _DragMode.stroke; // 경로는 긴데 시작점 근처를 맴돔
      } else if (_dragMode != _DragMode.roll &&
          straightness > kRollStraight &&
          net > ball.radius * kRollNetFactor) {
        _dragMode = _DragMode.roll; // 확실히 한 방향으로 멀리 끌고 감
      }

      // 모드별 동작
      if (_dragMode == _DragMode.stroke) {
        ball.stroke(step); // 제자리 출렁임
        _strokeEnergy = (_strokeEnergy + stepLen / ball.radius * 0.4)
            .clamp(0.0, 1.0); // step 비례 증가
        // 쓰다듬기 힐링(요구2): 1차 rubTick(딱딱한 light 반복) 대체. 위로받는
        // 느낌의 부드러운 저강도 텍스처를 흐르듯 발사(throttle은 strokeSoft 내장).
        Haptics.instance.strokeSoft();
      } else if (_dragMode == _DragMode.roll) {
        ball.grab(pos); // 손가락 추종
        // 굴리기 마찰감(요구3, §6.2): 이동 누적이 반경의 절반을 넘을 때마다
        // 마찰 틱을 발사 → 구슬 굴리는 자글거림. 손가락이 빠를수록 잦고 강하다.
        // speed01은 추종 속도(px/s)를 2600으로 정규화. throttle은 rollFriction 내장.
        _rollAccum += stepLen;
        final tickDist = ball.radius * 0.5;
        if (_rollAccum >= tickDist) {
          _rollAccum -= tickDist;
          final moveDt = (e.timeStamp - _lastMoveTime).inMicroseconds / 1e6;
          final speed01 =
              (moveDt > 0 ? (stepLen / moveDt) / 2600 : 0.0).clamp(0.0, 1.0);
          Haptics.instance.rollFriction(speed01);
        }
      }
    }

    // 플링 속도 추정
    final dtMs = (e.timeStamp - _lastMoveTime).inMicroseconds / 1e6;
    if (dtMs > 0) _flingVel = (pos - _lastPos) / dtMs;
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
      ball.release();
      ball.vel = _flingVel; // 던진 손맛(관성 fling)
    } else if (_dragMode == _DragMode.stroke) {
      ball.release(); // grabbed 해제만, vel 부여 안 함(날아가지 않음)
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
