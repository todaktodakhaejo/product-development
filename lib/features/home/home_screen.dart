import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:sensors_plus/sensors_plus.dart';

import '../../core/haptics.dart';
import '../../state/session.dart';
import '../writing/writing_screen.dart';
import 'emotion_ball.dart';
import 'emotion_ball_painter.dart';
import 'home_help_sheet.dart';
import 'home_messages.dart';
import 'release_counter.dart';
import 'sky_background.dart';

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
/// 커밋된 stroke는 net 탈출 없이 빠른 플릭(speed>kStrokeEscape)으로만 roll 전환(v8 §1-A).
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
  // 최근 최고 순간속도 추적(v8 §4): 떼기 직전 감속이 EMA에 섞여 빠른 플릭의 fling이
  // 약화되던 문제 → 매 유효 move에서 peak를 갱신(프레임당 *0.9 감쇠 + 최신 최대)해
  // release 시 EMA와 peak 중 큰 쪽을 채택, 빠른 손맛을 살린다. 다운 시 0 리셋.
  double _flingPeak = 0;
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

  // ── 멘트(§2/§3) / 터치→카운트(§1) ───────────────────────────
  // 멘트는 타이머 순환 폐기(v2 §3). 홈에 있는 동안 고정이며, 표시 멘트는
  // homeMessages[_releaseCount % 9]. 의식을 한 번 완료(releaseCount+1)할 때마다
  // 다음 세트로 자연히 넘어간다. AnimatedSwitcher fade는 멘트가 실제 바뀔 때만.
  // 현재 시각(날짜·시간 표시용). _onTick에서 분 단위로만 갱신.
  DateTime _now = DateTime.now();
  // 공을 한 번이라도 터치하면 true → 멘트/날짜/releaseCount fade-out,
  // interactionCount fade-in. 세션 동안 유지되고, 의식 완료 복귀(§1)나
  // 글쓰기 복귀 시에만 초기화된다.
  bool _touched = false;
  // 화면에 표시할 누적 흘려보냄 횟수(의식 완료 횟수). 진입 시·완료 시 갱신.
  int _releaseCount = 0;

  // ── 공 놀이(인터랙션) 카운트(v2 §1-B) ─────────────────────────
  // 공을 튕기고·흔들고·굴리고·만지고·누른 평생 누적 횟수. 진입 시 lifetime을
  // 비동기 로드해 메모리에서 증가시키고, 디스크 쓰기는 디바운스(주기 Timer/완료/
  // dispose)로만 한다. 매 제스처 setState는 ~100ms 스로틀로 리빌드 폭주 방지.
  int _interactionCount = 0;
  bool _interactionLoaded = false; // lifetime 로드 완료 여부
  int _interactionSavedAt = 0; // 마지막으로 디스크에 반영한 값
  Timer? _interactionSaveTimer; // 변경분 디바운스 저장(~3s 주기)
  // 실시간 표시 스로틀: 마지막으로 setState한 시각. 100ms 이내 증가는 리빌드 생략.
  DateTime _interactionShownAt = DateTime.fromMillisecondsSinceEpoch(0);

  // ── 의식 완료 감지(§6) — SessionScope listen만, P2/P3 무수정 ──────
  SessionState? _session; // didChangeDependencies에서 바인딩
  // ritual이 한 번이라도 non-null이 된 적 있으면 true. reset로 null이 될 때
  // 이 플래그가 켜져 있으면 '의식 완료'로 판정해 카운트를 올린다.
  bool _ritualWasChosen = false;

  Duration _lastTick = Duration.zero;

  static const double _slop = 14;

  // 흔들기(GST-01) 선형 가속도 임계(m/s², §1 강화). userAccelerometer는 중력이
  // 제거돼 정지 시 ≈0, 직선으로 흔들면 즉시 큰 값이 잡힌다. 임계를 낮춰(9) 쉽게
  // 발동하고, 상한을 26으로 당겨 강도가 빨리 포화된다.
  static const double kShakeOn = 9.0; // 발동 임계(12→9)
  static const double kShakeMax = 26.0; // 정규화 상한(32→26)
  static const Duration _shakeCooldown =
      Duration(milliseconds: 70); // 90→70 (v8 §2 연속 반응 즉각)

  // 드래그 판별 임계(v6 §2 — 속도 기반). 거리·방향전환 기반 상수는 폐기.
  static const double kRollSpeed = 900; // px/s, 손가락 속도가 이를 넘으면 굴리기(§1 완화: 420→900)
  static const double kRollNet = 1.2; // ×radius, 느려도 이만큼 끌면 굴리기
  // stroke 커밋 후 roll 탈출 임계(v8 §1-A). 커밋된 쓰다듬기에서는 net 기반 탈출을
  // 제거하고, 오직 명백한 빠른 플릭(이 속도 초과)일 때만 roll로 전환한다. 가로/세로/
  // 대각 어느 방향으로 넓게 쓰다듬어도 굴리기로 새지 않는다.
  static const double kStrokeEscape = 1300; // px/s
  // 손가락 속도 EMA/clamp 상수(v6 §1).
  static const double kDragMinDt = 0.004; // 이보다 짧은 dt 샘플은 속도 계산서 제외
  static const double kDragSpeedClamp = 4000; // 순간속도 magnitude 상한(px/s)
  static const int kRollCatchupFrames = 6; // stroke→roll 늦은 전환 시 따라잡기 프레임

  // 굴리기 fling 평활/clamp 상수(v5 §1).
  static const double kFlingMinDt = 0.004; // 이보다 짧은 dt 샘플은 속도 계산서 제외
  static const double kFlingSpikeClamp = 3000; // 순간속도 magnitude 스파이크 컷(px/s)
  static const double kFlingReleaseClamp =
      3600; // release 시 최종 속도 크기 상한(px/s, v8 §4: 3200→3600 빠른 굴리기 튕김↑)

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    _listenSensors();
    // 멘트 타이머 폐기(v2 §3): 멘트는 releaseCount 기반 고정. 진입 시 현재
    // releaseCount를 읽어 멘트 인덱스와 untouched 카운트 표시에 함께 쓴다.
    ReleaseCounter.read().then((value) {
      if (!mounted) return;
      setState(() => _releaseCount = value);
    });
    // 공 놀이 평생 누적(v2 §1-B): lifetime 로드 후 메모리에서 증가시킨다.
    ReleaseCounter.readInteraction().then((value) {
      if (!mounted) return;
      setState(() {
        _interactionCount = value;
        _interactionSavedAt = value;
        _interactionLoaded = true;
      });
    });
    // 변경분 디바운스 저장(~3s 주기): 그 사이 증가가 있었을 때만 디스크에 쓴다.
    _interactionSaveTimer =
        Timer.periodic(const Duration(seconds: 3), (_) => _flushInteraction());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 세션 완료 감지(§6): SessionScope를 listen만(읽기 전용). 안전 패턴으로
    // 인스턴스가 바뀌면 이전 리스너를 떼고 새로 건다(여기서 reset/write 호출 금지).
    final session = SessionScope.of(context);
    if (!identical(session, _session)) {
      _session?.removeListener(_onSessionChanged);
      _session = session;
      _session!.addListener(_onSessionChanged);
    }
  }

  /// 세션 변화 콜백(§6, 읽기 전용 판정).
  /// ritual이 한 번이라도 선택되면 _ritualWasChosen=true. 이후 글·의식이 모두
  /// 비워진 채(=reset 호출됨) 알림이 오면 '의식 완료'로 보고 카운트 +1 + 홈 초기화.
  void _onSessionChanged() {
    final s = _session;
    if (s == null || !mounted) return;
    if (s.ritual != null) {
      _ritualWasChosen = true;
      return;
    }
    // ritual==null. text까지 비고 직전에 의식을 골랐던 적이 있으면 완료.
    if (s.text.isEmpty && _ritualWasChosen) {
      _ritualWasChosen = false;
      // 흘려보냄 +1(영구) 후 홈 UI 초기화. 멘트도 새 releaseCount % 9로 넘어감.
      ReleaseCounter.increment().then((value) {
        if (!mounted) return;
        setState(() => _releaseCount = value);
      });
      // 의식 완료 시점에 인터랙션 누적분도 디스크에 반영(디바운스 보강).
      _flushInteraction();
      _restoreHomeInitial();
    }
  }

  /// 홈을 초기(untouched) 상태로 되돌린다(§1).
  /// 멘트+날짜+releaseCount 표시, interactionCount 숨김. interactionCount 값
  /// 자체는 평생 누적이므로 초기화하지 않는다(계속 누적).
  void _restoreHomeInitial() {
    if (!mounted) return;
    setState(() => _touched = false);
  }

  /// 공 놀이 1회 카운트(v2 §1-B). 공 위 pointer down 1회 또는 흔들기 임펄스
  /// 발사 1회마다 +1. lifetime 로드 전이면 카운트만 보류 없이 미루지 않고
  /// 메모리 증가만(로드 콜백이 들어오기 전 제스처는 드물고, 로드 시 덮어쓰므로
  /// 정확도를 위해 로드 완료 후부터 집계한다).
  void _bumpInteraction() {
    if (!_interactionLoaded) return; // lifetime 로드 전엔 집계 보류(덮어쓰기 방지)
    _interactionCount++;
    // 실시간 표시 스로틀(~100ms): 빠르게 증가해도 리빌드는 100ms마다 1회.
    // 단 untouched 상태면 카운트가 숨겨져 있어 굳이 리빌드하지 않는다.
    if (!_touched) return;
    final now = DateTime.now();
    if (now.difference(_interactionShownAt).inMilliseconds < 100) return;
    _interactionShownAt = now;
    if (mounted) setState(() {});
  }

  /// 메모리 누적분이 마지막 저장값과 다르면 디스크에 반영(디바운스/완료/dispose).
  void _flushInteraction() {
    if (!_interactionLoaded) return;
    if (_interactionCount == _interactionSavedAt) return;
    final v = _interactionCount;
    _interactionSavedAt = v;
    ReleaseCounter.saveInteraction(v);
  }

  void _listenSensors() {
    // 흔들기(GST-01): 선형 가속도(중력 제거, m/s²). v2의 자이로는 회전 각속도라
    // 직선 흔들기에 거의 안 잡혀 먹통이었음 → 가속도로 교체(§1). 미지원 기기/웹
    // 에서는 onError로 무시되어 흔들기만 비활성화되고 터치 제스처는 정상 동작한다.
    // 샘플링 가속(v8 §2): 기본 샘플링이 느려 흔들기 반응이 한 템포 지연됐다 →
    // gameInterval(약 20ms)로 빠르게 받아 즉각 반응한다. SensorInterval은 sensors_plus 제공.
    _accelSub = userAccelerometerEventStream(
      samplingPeriod: SensorInterval.gameInterval,
    ).listen(
      (e) {
        final mag = sqrt(e.x * e.x + e.y * e.y + e.z * e.z); // 가속도 크기(m/s²)
        // 발동 조건(§1): 임계 이상 + 쿨다운 경과. armed 게이트를 없애 연속으로
        // 흔들면 90ms마다 계속 임펄스가 쌓여 공이 통통 튀고 벽에 부딪힌다.
        if (mag < kShakeOn) return;
        final now = DateTime.now();
        if (now.difference(_lastShake) < _shakeCooldown) return;
        _lastShake = now;

        // 임펄스/진동 공통 세기 raw(v9 §1): 흔든 가속도를 0~1로 정규화한 단일 값.
        // kShakeOn=9, kShakeMax=26이므로 raw = ((mag-9)/(26-9)).clamp(0,1). 임펄스 하한
        // 적용 전 값이며, 아래 임펄스(하한 0.25)와 진동 3단(0.40/0.72)이 모두 이 raw를
        // 공유해 모션 세기와 진동 세기가 함께 변한다.
        final raw =
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
        _ball?.addImpulse(unit, max(0.25, raw)); // 모션 대비 위해 하한 0.25 유지
        // 진동 세기 연동(v9 §1): mag 기반 3단(12/19) 폐기 → 임펄스와 동일한 raw 기반
        // 3단으로 교체. raw<0.40 light, 0.40~0.72 medium, 0.72+ heavy. 경계를 약한 쪽으로
        // 올려 살살 흔들면 raw가 작아 light로 확정 → 세기별 진동 단차가 또렷해진다.
        // throttle:false로 흔들 때마다 발사해 모션 임펄스와 진동이 함께 변한다.
        final HapticLevel level;
        if (raw < 0.40) {
          level = HapticLevel.light;
        } else if (raw < 0.72) {
          level = HapticLevel.medium;
        } else {
          level = HapticLevel.heavy;
        }
        Haptics.instance.fire(level, throttle: false);
        _bumpInteraction(); // 흔들기 임펄스 발사 1회 = 공 놀이 +1(§1-B)
        _onTouched();
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

    // 날짜·시간 표시 갱신(§3): 분이 바뀐 경우에만 setState로 텍스트 갱신.
    final now = DateTime.now();
    if (now.minute != _now.minute || now.hour != _now.hour) {
      _now = now;
      if (mounted) setState(() {});
    }
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
    _flingPeak = 0; // 최고 순간속도 리셋(v8 §4)
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
      // 공 위 pointer down 1회 = 공 놀이 +1(§1-B). 누르기/굴리기/쓰다듬기 시작은
      // 모두 한 번의 손길이므로 down에서 한 번만 집계한다(이동 전환에서 중복 없음).
      _bumpInteraction();
    }
    _onTouched(); // HOME-04: 첫 터치에 멘트→카운트 전환(§1)
  }

  /// 공을 한 번이라도 터치하면(§1) 멘트/날짜/releaseCount fade-out → 같은
  /// 상단 자리에 interactionCount fade-in. 이미 전환됐으면 무시(세션 동안 유지).
  /// interactionCount 값은 _bumpInteraction에서 갱신되므로 여기선 전환만 한다.
  void _onTouched() {
    if (_touched) return;
    setState(() => _touched = true);
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

      // 판별(v8 §1-A): roll은 sticky. stroke 진입과 탈출 조건을 분리한다.
      //  - 초기(none): speed>kRollSpeed || net>r*kRollNet → roll, 아니면 stroke(v7 유지).
      //  - 커밋된 stroke: net 기반 탈출 제거. 오직 명백한 빠른 플릭(speed>kStrokeEscape)
      //    일 때만 roll로 전환 → 가로/세로/대각 넓게 쓰다듬어도 안 굴러간다.
      final bool wantRoll = _dragMode == _DragMode.stroke
          ? _dragSpeed > kStrokeEscape
          : (_dragSpeed > kRollSpeed || net > r * kRollNet);
      if (_dragMode != _DragMode.roll && wantRoll) {
        // ROLL 진입(sticky): 명백한 굴리기.
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
        // v8 §1-B: 현재 포인터 localPosition을 함께 넘겨 손가락 닿는 자리에 광택/변형이
        // 따라다니게 한다(공 이동은 0, 위치 반응은 motion·painter가 소비).
        ball.stroke(step, pos); // 제자리 고정 출렁임 + 위치 반응(공 이동 없음)
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
      // peak 갱신(v8 §4): 프레임당 *0.9 감쇠 + 최신 순간속도 크기의 최대. 떼기 직전
      // 감속에도 직전의 빠름이 남아 release에서 강한 fling으로 살아난다.
      final instantSpeed = instant.distance;
      _flingPeak = max(_flingPeak * 0.9, instantSpeed);
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
      // fling(v8 §4): 방향은 EMA(_flingVel) 방향을 유지하되, 크기는 EMA 크기와
      // peak*0.8 중 큰 쪽을 채택해 떼기 직전 감속에 묻힌 빠른 손맛을 살린다.
      // 최종 크기는 [0, kFlingReleaseClamp]로 clamp. 천천히 굴리면 peak도 작아 약하게.
      ball.release();
      final dir = _flingVel.distance > 0.001
          ? _flingVel / _flingVel.distance
          : Offset.zero;
      var sp = max(_flingVel.distance, _flingPeak * 0.8);
      if (sp > kFlingReleaseClamp) sp = kFlingReleaseClamp;
      ball.vel = dir * sp; // 던진 손맛(관성 fling)
    } else {
      // stroke / none(미커밋): grabbed 해제만, vel 부여 안 함(날아가지 않음, v6 §2).
      ball.release();
    }
    _moved = false;
    _dragMode = _DragMode.none;
  }

  void _goToWriting() {
    // 복귀 시(글쓰기 취소/뒤로) 홈을 멘트 화면으로 복원(§6 보강). 카운트 증가는
    // 의식 완료 감지(_onSessionChanged)에서만 일어나므로 여기선 UI만 초기화.
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const WritingScreen()))
        .then((_) => _restoreHomeInitial());
  }

  @override
  void dispose() {
    _interactionSaveTimer?.cancel();
    _flushInteraction(); // 마지막 누적분을 디스크에 반영
    _session?.removeListener(_onSessionChanged);
    _ticker.dispose();
    _accelSub?.cancel();
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // §2 소비: 홈만 motion의 SkyBackground로 감싼다(시간대 morph 배경).
    // 현재 tone에 맞춰 텍스트/카운트 가독성 색을 결정한다(아직 ValueListenable
    // 노출이 없으므로 계약대로 skyToneAt(now) 사용).
    final SkyTone tone = skyToneAt(DateTime.now());
    final bool dark = tone == SkyTone.dark;
    // 밝은 배경=어두운 글씨, 어두운 배경=밝은 글씨. 저대비로 은은하게.
    final Color msgColor =
        dark ? Colors.white.withValues(alpha: 0.82) : const Color(0xFF4A3B47);
    final Color subColor =
        dark ? Colors.white.withValues(alpha: 0.55) : const Color(0xFF6B5560);
    // 카운트는 더 저대비(공 경험 방해 금지, §4).
    final Color countColor =
        dark ? Colors.white.withValues(alpha: 0.62) : const Color(0x995A4651);
    final Color helpFg =
        dark ? Colors.white.withValues(alpha: 0.85) : const Color(0xFF5A4651);
    final Color helpBg = dark
        ? Colors.white.withValues(alpha: 0.14)
        : Colors.white.withValues(alpha: 0.55);

    return Scaffold(
      body: SkyBackground(
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

                  // 상단 중앙(§1): untouched는 멘트+날짜+releaseCount('N번째
                  // 흘려보냄'), touched는 같은 자리에 interactionCount fade-in.
                  // 같은 Stack 자리에서 AnimatedOpacity로 교차 fade. IgnorePointer로
                  // 공 터치 방해 없음.
                  Positioned(
                    top: 28,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: Column(
                        children: [
                          // 날짜·시간: 터치해도 사라지지 않고 항상 표시(유지).
                          Text(
                            _formatDateTime(_now),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              color: subColor,
                              letterSpacing: 0.3,
                            ),
                          ),
                          const SizedBox(height: 10),
                          // 멘트/카운트 교차 영역: untouched=멘트+releaseCount,
                          // touched=interaction 카운트(같은 자리 cross-fade).
                          Stack(
                            alignment: Alignment.topCenter,
                            children: [
                              AnimatedOpacity(
                                opacity: _touched ? 0 : 1,
                                duration: const Duration(milliseconds: 600),
                                child: Column(
                                  children: [
                                    // 멘트: releaseCount % 9 고정(의식 완료 시에만 전환).
                                    AnimatedSwitcher(
                                      duration:
                                          const Duration(milliseconds: 800),
                                      child: Text(
                                        homeMessages[
                                            _releaseCount % homeMessages.length],
                                        key: ValueKey(
                                            _releaseCount % homeMessages.length),
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: 18,
                                          color: msgColor,
                                          height: 1.5,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    // 흘려보냄 누적 횟수(§1-A). 터치하면 사라짐.
                                    Text(
                                      _releaseCount > 0
                                          ? '$_releaseCount번째 흘려보냄'
                                          : '오늘, 처음 흘려보낼까요',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 14,
                                        color: countColor,
                                        letterSpacing: 0.4,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              // touched: 공 놀이 횟수(§1-B)를 같은 자리에 fade-in.
                              // "{N} interaction" 형식, 노는 동안 실시간 증가.
                              AnimatedOpacity(
                                opacity: _touched ? 1 : 0,
                                duration: const Duration(milliseconds: 700),
                                child: Text(
                                  '$_interactionCount interaction',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: countColor,
                                    letterSpacing: 0.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),

                  // 상단 우측: 도움말 `?` 버튼(반투명 원, §5).
                  Positioned(
                    top: 20,
                    right: 16,
                    child: Material(
                      color: helpBg,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => HomeHelpSheet.show(context, tone),
                        child: SizedBox(
                          width: 40,
                          height: 40,
                          child: Icon(Icons.question_mark,
                              size: 18, color: helpFg),
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
                          foregroundColor: subColor,
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

  /// 상단에 작게 표시할 날짜·시간 포맷(예: '6월 4일 화요일 · 오후 9:05').
  String _formatDateTime(DateTime t) {
    const weekdays = ['월', '화', '수', '목', '금', '토', '일'];
    final wd = weekdays[t.weekday - 1];
    final isPm = t.hour >= 12;
    final h12 = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final ap = isPm ? '오후' : '오전';
    final mm = t.minute.toString().padLeft(2, '0');
    return '${t.month}월 ${t.day}일 $wd요일 · $ap $h12:$mm';
  }
}
