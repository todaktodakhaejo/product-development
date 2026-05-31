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
///  - GST-01 흔들기 : 자이로 각속도 세기 비례 임펄스 + 세기별 햅틱, 벽 충돌 진동
///  - GST-02 굴리기 : 손가락 드래그 추종 → 놓으면 관성 fling + 벽 튕김
///  - GST-03 누르기 : 탭 → 물결 + 뗄 때 'selection' 진동
///  - GST-04 쓰다듬기: 제자리 왕복 드래그 → 표면 출렁임 + 글로우 + 연속 약진동
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

  // 센서: 흔들기(GST-01)용 자이로 각속도 1개만 구독.
  StreamSubscription? _gyroSub;
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

  bool _showComfort = true;
  late final String _comfort = randomComfortMessage();

  Duration _lastTick = Duration.zero;

  static const double _slop = 14;

  // 흔들기(GST-01) 자이로 각속도 임계(rad/s)
  static const double kShakeOn = 3.5; // 발동 임계
  static const double kShakeOff = 2.0; // 해제(재발동 허용) 임계
  static const double kShakeMax = 12.0; // 정규화 상한
  static const Duration _shakeCooldown = Duration(milliseconds: 120);

  // 드래그 판별 임계(§6.2)
  static const double kTurnDot = -0.1; // 방향전환 인정 내적(약 95°)
  static const double kStrokeStraight = 0.45; // 미만 + 잦은 전환 → stroke
  static const double kRollStraight = 0.65; // 초과 + 큰 net → roll
  static const double kRollNetFactor = 0.8; // net > radius * 0.8
  static const int kStrokeTurns = 2; // 전환 횟수 임계
  static const double kMinStep = 2.0; // px, 노이즈 컷

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    _listenSensors();
  }

  void _listenSensors() {
    // 흔들기(GST-01): 자이로 각속도. 미지원 기기/웹에서는 onError로 무시되어
    // 흔들기만 비활성화되고 터치 제스처는 정상 동작한다.
    _gyroSub = gyroscopeEventStream().listen(
      (e) {
        final w = sqrt(e.x * e.x + e.y * e.y + e.z * e.z); // 각속도 크기(rad/s)
        if (w < kShakeOff) {
          _shakeArmed = true; // 충분히 잦아들면 다음 흔들기 허용
          return;
        }
        if (w < kShakeOn || !_shakeArmed) return;
        // 쿨다운(연속 발사 폭주 방지)
        final now = DateTime.now();
        if (now.difference(_lastShake) < _shakeCooldown) return;
        _lastShake = now;
        _shakeArmed = false;

        final strength =
            ((w - kShakeOn) / (kShakeMax - kShakeOn)).clamp(0.0, 1.0);
        _ball?.addImpulse(_randomUnitVector(), strength);
        // 임펄스가 발사된(=kShakeOn 각속도 게이트를 통과한) 흔들기는 반드시 손에
        // 느껴져야 한다. strength 원값은 임계 부근에서 0에 수렴해 impactByStrength의
        // 하한(0.12)에 걸려 무발동 → 시각은 튀는데 진동은 없는 desync가 생긴다.
        // 발사된 흔들기는 light(0.12) 이상이 보장되도록 바닥을 깔고, 셀수록 강하게
        // medium·heavy로 단계 상승시킨다(throttle은 120ms 쿨다운이 이미 담당).
        Haptics.instance.impactByStrength(
          (0.18 + strength * 0.82).clamp(0.0, 1.0),
          throttle: false,
        );
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
    _pointerId = e.pointer;
    _downPos = _lastPos = e.localPosition;
    _lastMoveTime = e.timeStamp;
    _moved = false;
    // 드래그 메트릭 초기화
    _dragMode = _DragMode.none;
    _pathLen = 0;
    _turnCount = 0;
    _lastMoveDir = Offset.zero;
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

      // 히스테리시스 판정: 0.45~0.65 데드존으로 모드 떨림 방지.
      if (_dragMode != _DragMode.stroke &&
          straightness < kStrokeStraight &&
          _turnCount >= kStrokeTurns) {
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
        Haptics.instance.rubTick(); // 연속 약진동(throttle 내장)
      } else if (_dragMode == _DragMode.roll) {
        ball.grab(pos); // 손가락 추종
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
      // 누르기(GST-03): 물결 + 뗄 때 진동
      _ripples.add(Ripple(e.localPosition));
      Haptics.instance.fire(HapticLevel.selection, throttle: false);
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
    _gyroSub?.cancel();
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
