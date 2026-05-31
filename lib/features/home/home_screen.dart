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

/// 2단계 첫 화면(홈). 감정 오브제(공)와 5개 제스처 인터랙션의 무대.
///
///  - GST-01 흔들기 : userAccelerometer 임펄스 + 세기별 햅틱, 벽 충돌 진동
///  - GST-02 굴리기 : accelerometer 기울기 중력, 시작/충돌 진동
///  - GST-03 누르기 : 탭 → 물결 + 뗄 때 'selection' 진동
///  - GST-04 문지르기: 드래그 → 젤리 출렁임 + 지속 약진동
///  - GST-05 꽉쥐기 : 공 위 정지 유지 → 충전 진동 점증 → 임계 돌파 시 팡(종이 등장)
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<int> _frame = ValueNotifier(0);

  EmotionBall? _ball;
  final List<Ripple> _ripples = [];

  // 센서
  StreamSubscription? _accelSub;
  StreamSubscription? _userAccelSub;
  Offset _gravity = Offset.zero; // 기울기에서 온 가속도
  bool _rolling = false;

  // 포인터 상태 (누르기/문지르기/꽉쥐기 통합)
  int? _pointerId;
  Offset _downPos = Offset.zero;
  Offset _lastPos = Offset.zero;
  Duration _lastMoveTime = Duration.zero;
  Offset _flingVel = Offset.zero;
  bool _moved = false;
  bool _onBall = false;
  double _squeeze = 0; // GST-05 충전 0~1
  static const double _squeezeTime = 1.4; // 초

  bool _showComfort = true;
  late final String _comfort = randomComfortMessage();

  Duration _lastTick = Duration.zero;

  static const double _gravityScale = 55;
  static const double _slop = 14;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    _listenSensors();
  }

  void _listenSensors() {
    // 굴리기(GST-02): 기기 기울기 → 중력 벡터
    _accelSub = accelerometerEventStream().listen(
      (e) {
        // 화면 좌표: x 오른쪽+, y 아래+. 기기 기울기를 굴림 방향으로 매핑.
        // (부호는 기기/OS에 따라 튜닝 필요)
        _gravity = Offset(e.x, -e.y) * _gravityScale;
        final mag = _gravity.distance;
        if (!_rolling && mag > 90) {
          _rolling = true;
          Haptics.instance.fire(HapticLevel.light); // 굴리기 시작 알림
        } else if (_rolling && mag < 45) {
          _rolling = false;
        }
      },
      onError: (_) {}, // 센서 미지원 기기에서도 터치는 동작
      cancelOnError: false,
    );

    // 흔들기(GST-01): 중력 제외 사용자 가속도
    _userAccelSub = userAccelerometerEventStream().listen(
      (e) {
        final mag = sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
        if (mag > 12) {
          final strength = ((mag - 12) / 22).clamp(0.0, 1.0);
          final dir = Offset(e.x, -e.y);
          final n = dir.distance;
          if (n > 0.001) _ball?.addImpulse(dir / n, strength);
          Haptics.instance.impactByStrength(strength.toDouble());
          if (_showComfort) setState(() => _showComfort = false);
        }
      },
      onError: (_) {},
      cancelOnError: false,
    );
  }

  void _onTick(Duration elapsed) {
    final dt = _lastTick == Duration.zero
        ? 0.016
        : (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    final ball = _ball;
    if (ball == null) return;
    final clampedDt = dt.clamp(0.0, 0.05);

    // 꽉쥐기(GST-05): 공 위에서 정지 유지 시 충전
    if (_pointerId != null && _onBall && !_moved) {
      _squeeze = (_squeeze + clampedDt / _squeezeTime).clamp(0.0, 1.0);
      // 충전될수록 더 잦고 센 진동
      Haptics.instance.fire(
        _squeeze < 0.5 ? HapticLevel.light : HapticLevel.medium,
      );
      if (_squeeze >= 1.0) {
        _pop();
        return;
      }
    }

    ball.update(clampedDt, _gravity);

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
    _onBall = ball.hitTest(e.localPosition);
    _squeeze = 0;
    if (_showComfort) setState(() => _showComfort = false); // HOME-04
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (e.pointer != _pointerId) return;
    final ball = _ball;
    if (ball == null) return;
    final pos = e.localPosition;
    if (!_moved && (pos - _downPos).distance > _slop) {
      _moved = true;
      _squeeze = 0; // 움직였으면 꽉쥐기 아님 → 문지르기
    }
    if (_moved && _onBall) {
      ball.grab(pos); // 문지르기(GST-04)
      Haptics.instance.rubTick(); // throttle 내장
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
    _squeeze = 0;

    if (ball == null) return;
    if (!_moved) {
      // 누르기(GST-03): 물결 + 뗄 때 진동
      _ripples.add(Ripple(e.localPosition));
      Haptics.instance.fire(HapticLevel.selection, throttle: false);
    } else if (_onBall) {
      ball.release();
      ball.vel = _flingVel; // 던진 손맛
    }
    _moved = false;
    _onBall = false;
  }

  /// GST-05 임계 돌파: 팡 → 종이가 튀어나오듯 글쓰기로 전환(HOME-05).
  void _pop() {
    _squeeze = 0;
    _pointerId = null;
    Haptics.instance.fire(HapticLevel.heavy, throttle: false);
    _goToWriting();
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
    _userAccelSub?.cancel();
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
                          squeeze: _squeeze,
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

                  // 글쓰기 전환 힌트 + 접근성 대체 버튼 (HOME-05)
                  Positioned(
                    bottom: 24,
                    left: 0,
                    right: 0,
                    child: Column(
                      children: [
                        const Text(
                          '공을 꾹 쥐면 종이가 나와요',
                          style: TextStyle(color: Colors.white38, fontSize: 13),
                        ),
                        const SizedBox(height: 8),
                        TextButton.icon(
                          onPressed: _goToWriting,
                          icon: const Icon(Icons.edit_note, size: 18),
                          label: const Text('바로 글쓰기'),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white60,
                          ),
                        ),
                      ],
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
