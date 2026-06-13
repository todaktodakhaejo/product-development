import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/analytics.dart';
import '../../core/haptics.dart';
import '../../core/ritual_audio.dart';
import '../../state/analytics_scope.dart';
import '../../state/session.dart';
import '../writing/writing_screen.dart';
import 'emotion_ball.dart';
import 'emotion_ball_painter.dart';
import 'emotion_ball_shader_painter.dart';
import 'home_help_sheet.dart';
import 'home_messages.dart';
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
/// 한국어 멘트가 단어(어절) 중간에서 줄바꿈되는 걸 막는다(keep-all).
///
/// Flutter 기본 줄바꿈은 한글을 글자 단위로 끊을 수 있어 "오셨네요"가 "오셨/네요"로
/// 쪼개진다. 각 어절(공백 구분) 내부 글자 사이에 WORD JOINER(U+2060, break 금지)를
/// 넣어, 줄바꿈이 **어절 사이 공백에서만** 일어나게 한다(어절은 짧아 넘침 없음).
String _keepAll(String s) {
  const wj = '⁠'; // WORD JOINER — 이 위치 줄바꿈 금지
  return s.split(' ').map((w) => w.split('').join(wj)).join(' ');
}

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
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker;
  final ValueNotifier<int> _frame = ValueNotifier(0);

  // 3D 함몰용 프래그먼트 셰이더(비동기 로드). 로드 전/실패 시 기존 painter로 폴백.
  ui.FragmentShader? _ballShader;

  EmotionBall? _ball;
  final List<Ripple> _ripples = [];

  // 센서: 흔들기(GST-01)용 선형 가속도(중력 제거) 1개만 구독.
  StreamSubscription? _accelSub;
  // armed 게이트 제거(§1): 연속 흔들기에서 가속도가 임계 아래로 안 떨어져
  // 재발동이 막히던 문제 → 쿨다운(90ms)만으로 게이팅한다.
  DateTime _lastShake = DateTime.fromMillisecondsSinceEpoch(0);

  // 흔들기 임펄스 방향용 난수(State 당 1개만 보유).
  final Random _rng = Random();

  // ── 분석(PostHog) ──────────────────────────────────────────────
  AnalyticsService? _analytics; // didChangeDependencies에서 바인딩
  bool _homeViewedSent = false; // home_viewed 1회만 전송
  // 제스처 지속시간(ms) 계산용 시작 타임스탬프(포인터 이벤트 timeStamp 기준).
  Duration _pressDownTime = Duration.zero;
  Duration _rollStartTime = Duration.zero;
  Duration _strokeStartTime = Duration.zero;
  // 흔들기 분석은 "한 사이클(흔들기 시작→멈춤)당 1회"로 집계한다(사용자 요청 2026-06-09).
  // 흔드는 동안 임펄스가 연속으로 들어오므로, 마지막 임펄스 후 _shakeCycleGap 동안
  // 추가 임펄스가 없으면 사이클이 끝난 것으로 보고 그때 1회 발사(지속시간 = 마지막-시작).
  bool _shakeCycleActive = false; // 흔들기 사이클 진행 중
  DateTime _shakeCycleStart = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastShakeImpulse = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _shakeEndTimer; // 사이클 종료(디바운스) 감지
  static const Duration _shakeCycleGap = Duration(milliseconds: 600);

  // 포인터 상태 (누르기 / 굴리기 / 쓰다듬기 통합)
  int? _pointerId;
  Offset _downPos = Offset.zero;
  // 누르기 시작이 공 위였는지(v16). 공 위에서 시작한 제스처는 "문지르기"가 기본이고
  // 속도와 무관하게 공을 멀리 끌고 갔을 때(net>반지름×1.2)만 굴리기로 전환한다.
  bool _downOnBall = false;
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

  // ── 두 손가락 늘리기(stretch, GST-05) 라우팅 상태 ───────────────────
  // 단일 포인터 상태머신(_dragMode)은 주 포인터 1개만 구동하고, 둘째 손가락은
  // 함몰점(extraPress)만 만든다. 스트레치는 "두 손가락이 모두 공 위"일 때만 켜져
  // 두 손가락의 거리·각도로 ball.stretch*를 구동한다. 활성 중엔 주 포인터의
  // stroke/roll 판별을 건너뛰어(공이 굴러가지 않게) 늘리기에만 반응한다. 함몰점은
  // 그대로 유지되므로 함몰 골 + 전체 늘림이 동시에 보인다(사용자 결정 ①).
  final Map<int, Offset> _activePointers = {}; // 모든 활성 포인터의 현재 좌표
  bool _stretchActive = false; // 두 손가락 스트레치 진행 중
  int? _stretchA; // 스트레치 중인 주 포인터 id
  int? _stretchB; // 스트레치 중인 둘째 포인터 id
  // 늘리는 중 쫀득 사운드 폭주 방지 — along 스케일이 일정량 변할 때만 1발씩.
  double _lastStretchSoundAlong = 1.0;
  // 분석(PostHog)용: 스트레치 지속시간·최대 늘림 추적.
  Duration _stretchStartTime = Duration.zero;
  double _stretchPeakAlong = 1.0; // 제스처 중 도달한 최대 along 스케일

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
  // 화면에 표시할 누적 흘려보냄 횟수(의식 완료 횟수, 세션 한정). 멘트 인덱스 구동.
  int _releaseCount = 0;
  // 오늘 첫 실행 여부(날짜 기준). true면 둘째 줄을 '오늘, 처음 흘려보낼까요'로.
  // 날짜 문자열 1개만 영구 저장해 판정 — 하루에 한 번만 뜨고, 같은 날 재실행
  // (앱 종료/사용기록 삭제 후 재진입 포함)에는 일반 멘트 둘째 줄을 보여준다.
  bool _showDailyGreeting = false;

  // ── 공 놀이(인터랙션) 카운트 ──────────────────────────────────
  // 공을 튕기고·흔들고·굴리고·만지고·누른 횟수. **세션 한정** — 영구 저장하지
  // 않으므로 앱을 나갔다 들어오면 0으로 리셋된다(의식 횟수와 동일 정책). 0에서
  // 시작해 저장소 로드가 없으므로, 첫 제스처부터 지연 없이 즉시 카운트된다.
  int _interactionCount = 0;

  // ── 의식 완료 감지(§6) — SessionScope listen만, P2/P3 무수정 ──────
  SessionState? _session; // didChangeDependencies에서 바인딩
  // ritual이 한 번이라도 non-null이 된 적 있으면 true. reset로 null이 될 때
  // 이 플래그가 켜져 있으면 '의식 완료'로 판정해 카운트를 올린다.
  bool _ritualWasChosen = false;

  Duration _lastTick = Duration.zero;

  static const double _slop = 14;

  // ── 홈 레이아웃 상수(§C, 프로토타입 Home.tsx 기준) ──────────────
  // 날짜는 상단 중앙(SafeArea 기준 top).
  static const double _kDateTop = 32;
  // 멘트 블록 최소 상단 여백(작은 기기에서 날짜와 겹침 방지).
  static const double _kMsgBoxMinTop = 68;
  // 하단 힌트 위치(바로 글쓰기 버튼 위에 띄움).
  static const double _kHintBottom = 88;

  // 흔들기(GST-01) 선형 가속도 임계(m/s²). userAccelerometer는 중력이 제거돼
  // 정지 시 ≈0, 직선으로 흔들면 큰 값이 잡힌다. #5 둔감화(2026-06-14): 걷기 발구름
  // 단발 스파이크(≈6~10)에도 발동하던 문제 → 임계를 9→14로 올려 '격한 흔들기'만
  // 잡고, 상한도 26→34로 올려 raw 정규화가 새 바닥에 맞게 분포되게 한다.
  static const double kShakeOn = 14.0; // 발동 임계(9→14, 둔감화)
  static const double kShakeMax = 34.0; // 정규화 상한(26→34)
  static const Duration _shakeCooldown =
      Duration(milliseconds: 70); // 90→70 (v8 §2 연속 반응 즉각)

  // #5 흔들기 무장(arming): 새 사이클은 짧은 창(_shakeArmWindow) 안에 임계 이상
  // 샘플이 2회 이상 들어와야 시작한다 — 걷기 같은 '단발' 스파이크는 1회로 끝나
  // 무장만 되고 발동되지 않는다(격하게 '흔들면' 짧은 시간에 여러 피크가 잡힌다).
  // 사이클이 이미 진행 중이면 무장 게이트를 건너뛰어 즉각 반응을 유지한다.
  DateTime _shakeArmTime = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _shakeArmWindow = Duration(milliseconds: 350);

  // 드래그 판별 임계(v6 §2 — 속도 기반). 거리·방향전환 기반 상수는 폐기.
  static const double kRollSpeed = 650; // px/s, 손가락 속도가 이를 넘으면 굴리기(900→650: 굴리기 시작 더 쉽게)
  static const double kRollNet = 0.5; // ×radius, 느려도 이만큼 끌면 굴리기(0.7→0.5: 천천히 끌어도 금방 따라와 데굴데굴)
  // stroke 커밋 후 roll 탈출 임계(v8 §1-A). 커밋된 쓰다듬기에서는 net 기반 탈출을
  // 제거하고, 오직 명백한 빠른 플릭(이 속도 초과)일 때만 roll로 전환한다. 가로/세로/
  // 대각 어느 방향으로 넓게 쓰다듬어도 굴리기로 새지 않는다.
  static const double kStrokeEscape = 1300; // px/s (공 밖 시작 stroke의 roll 탈출용)
  // v16: 공 위에서 시작한 제스처가 굴리기로 전환되는 net 이동 임계(×radius). 제자리
  // 문지르기는 net이 작게 왕복하므로(시작점 기준 변위) 이 값을 넘지 않아 안 굴러간다.
  // 공을 확실히 끌고 갔을 때만(시작점에서 1.2반지름 이상 멀어짐) 굴리기로 커밋.
  static const double kRollNetOnBall = 1.2;
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
    WidgetsBinding.instance.addObserver(this); // 생명주기 관찰(#1 백그라운드 정지)
    _ticker = createTicker(_onTick)..start();
    _listenSensors();
    // 흘려보냄 횟수(releaseCount)·공 놀이 횟수(interactionCount) **둘 다 세션 한정** —
    // 앱을 나갔다 들어오면 0으로 리셋한다(영구 저장 안 함). 둘 다 0에서 시작하고
    // 저장소 로드(비동기)가 없으므로, 첫 제스처부터 카운트가 지연 없이 즉시 반영된다.
    // 멘트는 releaseCount % 9로 세트가 넘어가므로, 재실행하면 첫 멘트부터 다시 시작한다.
    _checkDailyFirst();
    _loadBallShader();
  }

  /// 공 3D 함몰 셰이더 로드(웹 미지원 시 폴백). 성공하면 그 painter로 전환.
  Future<void> _loadBallShader() async {
    try {
      final program = await ui.FragmentProgram.fromAsset('shaders/ball.frag');
      if (mounted) setState(() => _ballShader = program.fragmentShader());
    } catch (_) {
      // 셰이더 미지원/실패 → 기존 EmotionBallPainter로 그대로 진행.
    }
  }

  /// 오늘 첫 실행인지 날짜로 판정. 저장된 마지막 날짜와 오늘이 다르면 '오늘 처음'
  /// 으로 보고 [_showDailyGreeting]을 켠다(둘째 줄 → '오늘, 처음 흘려보낼까요').
  /// 같은 날 두 번째 실행부터는(앱 종료·사용기록 삭제 후 재진입 포함) 끄여 있어
  /// 일반 멘트 둘째 줄을 보여준다 — 하루 한 번만 인사. 날짜 문자열 1개만 영구 저장.
  Future<void> _checkDailyFirst() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      final today = '${now.year}-${now.month}-${now.day}';
      if (prefs.getString('last_greet_date') != today) {
        await prefs.setString('last_greet_date', today);
        if (mounted) setState(() => _showDailyGreeting = true);
      }
    } catch (_) {
      // 저장소 접근 실패 시 그냥 일반 멘트로(폴백).
    }
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
    // 분석 바인딩 + 홈 표시 1회 전송(센서 콜백 등 context 없는 곳에서도 쓰려고 보관).
    _analytics = AnalyticsScope.of(context);
    if (!_homeViewedSent) {
      _homeViewedSent = true;
      _analytics?.homeViewed();
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
      // 흘려보냄 +1(세션 한정 in-memory, 영구 저장 안 함) 후 홈 UI 초기화.
      // 멘트도 새 releaseCount % 9로 넘어간다. 앱 재실행 시 0으로 리셋된다.
      setState(() => _releaseCount++);
      _restoreHomeInitial();
    }
  }

  /// 홈을 초기(untouched) 상태로 되돌린다(§1).
  /// 멘트+날짜+releaseCount 표시, interactionCount 숨김. interactionCount 값
  /// 자체는 평생 누적이므로 초기화하지 않는다(계속 누적).
  void _restoreHomeInitial() {
    if (!mounted) return;
    _ball?.recenter(); // 의식/글쓰기에서 돌아오면 말랑이를 가운데 원래 자리로
    setState(() => _touched = false);
  }

  /// 공 놀이 1회 카운트. 공 위 pointer down 1회 또는 흔들기 임펄스 발사 1회마다 +1.
  /// 세션 한정 메모리 값이라 로드 대기가 없어 즉시 증가한다.
  void _bumpInteraction() {
    _interactionCount++;
    // 즉시 반영(스로틀·로드 게이트 없음 — 바로바로 숫자가 올라가야 한다).
    // _bumpInteraction은 터치 다운·흔들기 임펄스 같은 '이벤트'마다만 불려 빈도가
    // 높지 않으므로 매번 setState해도 부담이 적다. untouched(숨김)면 리빌드 생략.
    if (!_touched) return;
    if (mounted) setState(() {});
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
        // 손가락이 화면에 닿아 있는 동안엔 흔들기를 무시한다(사용자 피드백 2026-06-09).
        // 쓰다듬기/굴리기 중 폰이 미세하게 흔들려 센서가 흔들기로 오인 → 공이 튕기던
        // 문제 차단. 터치를 떼면(_activePointers 비면) 다시 흔들기 활성.
        if (_activePointers.isNotEmpty) return;
        final mag = sqrt(e.x * e.x + e.y * e.y + e.z * e.z); // 가속도 크기(m/s²)
        // 발동 조건(§1): 임계 이상 + 쿨다운 경과. armed 게이트를 없애 연속으로
        // 흔들면 90ms마다 계속 임펄스가 쌓여 공이 통통 튀고 벽에 부딪힌다.
        if (mag < kShakeOn) return;
        final now = DateTime.now();
        // #5 무장 게이트: 흔들기 사이클이 아직 시작 전이면, '단발' 스파이크(걷기)는
        // 무시하고 짧은 창 안에 두 번째 자격 샘플이 와야 발동한다(격한 흔들기만).
        if (!_shakeCycleActive) {
          if (now.difference(_shakeArmTime) > _shakeArmWindow) {
            _shakeArmTime = now; // 첫 자격 샘플 — 무장만, 이번엔 발동 안 함.
            return;
          }
          // 창 안 두 번째 자격 샘플 → 격한 흔들기로 확정, 아래로 진행해 발동.
        }
        if (now.difference(_lastShake) < _shakeCooldown) return;
        _lastShake = now;

        // 임펄스/진동 공통 세기 raw(v9 §1): 흔든 가속도를 0~1로 정규화한 단일 값.
        // kShakeOn=14, kShakeMax=34이므로 raw = ((mag-14)/(34-14)).clamp(0,1). 임펄스 하한
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
        // 흔들기는 공 놀이 횟수(interaction)·PostHog 둘 다 "한 사이클(시작→멈춤)당 1회"로
        // 집계한다(사용자 요청). 흔드는 동안 임펄스가 연속으로 들어오지만, 사이클 시작에
        // interaction을 1회만 올리고(임펄스마다 X), 마지막 임펄스 후 _shakeCycleGap 동안
        // 추가 임펄스가 없으면(디바운스 타이머) 그때 PostHog로 1회 발사(지속시간=마지막-시작).
        final nowT = DateTime.now();
        if (!_shakeCycleActive) {
          _shakeCycleActive = true;
          _shakeCycleStart = nowT;
          _bumpInteraction(); // 사이클 시작 1회만(임펄스마다 올리지 않음)
        }
        _lastShakeImpulse = nowT;
        _shakeEndTimer?.cancel();
        _shakeEndTimer = Timer(_shakeCycleGap, () {
          _analytics?.gesturePerformed('shake',
              _lastShakeImpulse.difference(_shakeCycleStart).inMilliseconds);
          _shakeCycleActive = false;
        });
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
      RitualAudio.instance.objetSquish(gain: 0.7, throttle: true); // 벽 충돌 스퀴시
    }

    // 누르기 홀드 중 미세 틱(§2): 침몰 깊이가 깊어지는 정점(0.5·0.85 통과)을 ball이
    // 물리에서 단일 소스로 내보낸다. 프레임당 1회만 소비해 미세 틱 햅틱을 발사 →
    // 시각 침몰과 햅틱이 desync 없이 동기. (시작 pressDown·뗄 때 pressRelease는 포인터에서.)
    if (ball.consumePressHoldTick()) {
      Haptics.instance.pressHoldTick();
      RitualAudio.instance.objetStretch(gain: 0.5); // 깊게 눌러 늘어나는 쫀득
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
    final ball = _ball;
    if (ball == null) return;
    final pos = e.localPosition;
    _activePointers[e.pointer] = pos; // 두 손가락 늘리기(GST-05) 추적용
    // 멀티터치(v14): 주 포인터가 이미 있으면, 추가 손가락은 본체 위일 때 독립
    // 함몰점으로만 동작한다(양 엄지로 두 군데 동시 누르기). 굴리기/쓰다듬기·fling
    // 상태머신은 주 포인터 1개만 구동하므로 추가 손가락은 건드리지 않는다.
    if (_pointerId != null) {
      if (ball.hitTest(pos)) {
        ball.extraPressStart(e.pointer, pos);
        Haptics.instance.pressDown();
        _bumpInteraction();
        _onTouched();
        // 주 포인터도 공 위면 두 손가락 늘리기(GST-05)로 진입(함몰점은 유지).
        _maybeStartStretch(e.pointer, e.timeStamp);
      }
      return;
    }
    _pointerId = e.pointer;
    _downPos = _lastPos = pos;
    _downOnBall = ball.hitTest(pos); // 공 위 시작? → 문지르기 기본 분기 결정
    _lastMoveTime = e.timeStamp;
    _pressDownTime = e.timeStamp; // 누르기 지속시간 측정 시작점
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
    if (_downOnBall) {
      ball.pressStart(pos);
      Haptics.instance.pressDown();
      RitualAudio.instance.objetSquish(gain: 1.0); // 누르기 시작 슬라임 스퀴시
      RitualAudio.instance.objetStretch(gain: 0.55); // + 쫀득 몰캉 레이어
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
    final ball = _ball;
    if (ball == null) return;
    // 멀티터치(v14): 추가 손가락 이동 → 그 함몰점이 손가락을 따라간다(없으면 무시).
    if (e.pointer != _pointerId) {
      ball.extraPressMove(e.pointer, e.localPosition);
      _activePointers[e.pointer] = e.localPosition;
      if (_stretchActive) _updateStretch(); // 둘째 손가락 이동도 늘림에 반영
      return;
    }
    final pos = e.localPosition;
    _activePointers[e.pointer] = pos;
    // 두 손가락 늘리기(GST-05) 중이면 주 포인터 이동은 늘림에만 반영하고,
    // 단일 포인터 stroke/roll 판별은 건너뛴다(공이 굴러가거나 stroke되지 않게).
    if (_stretchActive) {
      _updateStretch();
      _lastPos = pos;
      _lastMoveTime = e.timeStamp;
      return;
    }
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
      // v16: 침몰은 여기서 취소하지 않는다 — 공 위에서 시작했으면(문지르기) 손가락을
      // 따라가는 이동 함몰로 이어가고, 굴리기로 확정되는 순간에만 아래에서 취소한다.
      _dragMode = _DragMode.none;
    }

    if (_moved) {
      // v20 §2: 빈 공간에서 시작한 드래그는 공을 굴리거나(순간이동) 문지르지 않고,
      // 손가락 지점으로 공을 탄성으로 "쭈욱 당겨온다"(glide). 매 move마다 목표만 갱신하면
      // ball.update가 부드럽게 따라온다. (공 위에서 시작한 제스처는 아래 기존 판별로.)
      if (!_downOnBall) {
        ball.glideTo(pos);
        _lastPos = pos;
        _lastMoveTime = e.timeStamp;
        return;
      }

      final net = (pos - _downPos).distance;
      final r = ball.radius;

      // 판별(v8 §1-A): roll은 sticky. stroke 진입과 탈출 조건을 분리한다.
      //  - 초기(none): speed>kRollSpeed || net>r*kRollNet → roll, 아니면 stroke(v7 유지).
      //  - 커밋된 stroke: net 기반 탈출 제거. 오직 명백한 빠른 플릭(speed>kStrokeEscape)
      //    일 때만 roll로 전환 → 가로/세로/대각 넓게 쓰다듬어도 안 굴러간다.
      // v16: 공 위에서 시작한 제스처는 "문지르기"가 기본 — 속도는 무시하고, 공을
      // 확실히 끌고 갔을 때(시작점에서 net>반지름×1.2)만 굴리기로 전환한다. 제자리
      // 문지르기는 시작점 기준 변위가 작게 왕복하므로 이 임계를 넘지 않아 안 굴러간다.
      // (세게/빠르게 문질러도 속도 때문에 굴러가던 문제 해결.)
      // 공 밖에서 시작한 드래그는 함몰 대상이 아니므로 기존 속도/거리 판정을 유지한다.
      final bool wantRoll = _downOnBall
          ? net > r * kRollNetOnBall
          : (_dragMode == _DragMode.stroke
              ? _dragSpeed > kStrokeEscape
              : (_dragSpeed > kRollSpeed || net > r * kRollNet));
      if (_dragMode != _DragMode.roll && wantRoll) {
        // ROLL 진입(sticky): 명백한 굴리기.
        final wasStroke = _dragMode == _DragMode.stroke;
        _dragMode = _DragMode.roll;
        _rollStartTime = e.timeStamp; // 굴리기 지속시간 측정 시작점
        ball.pressCancel(); // 혹시 남은 침몰 무팝 제거
        Haptics.instance.fire(HapticLevel.light); // roll 첫 진입 알림 1회
        // stroke에서 늦게 전환됐으면 공이 손가락과 벌어져 있으므로 ease 추종으로
        // 몇 프레임 따라잡는다(처음부터 빠른 굴리기는 gap이 거의 없어 불필요).
        if (wasStroke) _rollCatchup = kRollCatchupFrames;
      } else if (_dragMode != _DragMode.roll) {
        // STROKE: 느리고 국소. 공은 제자리, 손가락 자리가 골처럼 파이며 따라온다.
        final firstStroke = _dragMode != _DragMode.stroke;
        _dragMode = _DragMode.stroke;
        if (firstStroke) _strokeStartTime = e.timeStamp; // 문지르기 시작점
        // v17: 문지르기 진입 순간, 정지 누르기 함몰을 팝 없이 제거해 "이동 골"로 인계한다.
        // 이후 골은 ball.stroke가 갱신하는 strokeContact를 따라 pressPoints가 그린다.
        if (firstStroke) ball.pressCancel();
        // v8 §1-B: 현재 포인터 localPosition을 함께 넘겨 손가락 닿는 자리에 골/글로우가
        // 따라다니게 한다(공 이동은 0 — strokeContact·strokeAmp만 갱신).
        ball.stroke(step, pos); // 제자리 + 이동 함몰(strokeContact) + 둘레 글로우
        _strokeEnergy =
            (_strokeEnergy + stepLen / r * 0.4).clamp(0.0, 1.0); // step 비례 증가
        // 위로받는 부드러운 저강도 텍스처를 흐르듯 발사(throttle은 strokeSoft 내장).
        Haptics.instance.strokeSoft();
        // 문지르는 동안엔 슬라이스 retrigger(뚝뚝 끊김) 대신 부드러운 rub 루프를
        // 손 뗄 때까지 연속으로 켠다(startRub은 이미 켜져 있으면 무시).
        RitualAudio.instance.startRub();
      }

      // ROLL 거동: catchup 중엔 ease 추종으로 gap을 좁히고, 이후 full 추종.
      if (_dragMode == _DragMode.roll) {
        RitualAudio.instance.stopRub(); // 굴리기로 전환되면 문지르기 rub 정지
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
          RitualAudio.instance
              .objetSquish(gain: 0.5, throttle: true); // 굴리기 마찰 슬라임
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
    final ball = _ball;
    if (ball == null) return;
    _activePointers.remove(e.pointer);
    // 두 손가락 늘리기(GST-05): 쌍 중 하나라도 떨어지면 스프링백으로 종료한다.
    // 떼는 손가락의 함몰 복원(아래 기존 경로)은 그대로 이어 수행한다.
    if (_stretchActive && (e.pointer == _stretchA || e.pointer == _stretchB)) {
      // 분석(PostHog): 늘리기 1회 — 지속시간 + 최대 늘림(peak_stretch, along 배율 2자리).
      _analytics?.gesturePerformed(
        'stretch',
        (e.timeStamp - _stretchStartTime).inMilliseconds,
        extra: {'peak_stretch': (_stretchPeakAlong * 100).roundToDouble() / 100},
      );
      _endStretch();
    }
    // 멀티터치(v14): 추가 손가락을 떼면 그 함몰점만 복원(주 포인터 상태는 불변).
    if (e.pointer != _pointerId) {
      ball.extraPressEnd(e.pointer);
      Haptics.instance.pressRelease();
      return;
    }
    _pointerId = null;
    RitualAudio.instance.stopRub(); // 손 뗄 때 문지르기 rub 정지
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
        // 떼는 순간 "뽁" 팝: squelch + 쫀득 mochi 레이어를 겹쳐 통통 튀는 손맛(ⓔ).
        RitualAudio.instance.objetSquelch();
        RitualAudio.instance.objetStretch(gain: 0.7);
        _analytics?.gesturePerformed(
            'press', (e.timeStamp - _pressDownTime).inMilliseconds);
      } else {
        // v20 §2: 빈 공간을 탭하면 그 지점으로 공을 탄성으로 당겨온다(순간이동 대신).
        ball.glideTo(pos);
        Haptics.instance.fire(HapticLevel.light);
        RitualAudio.instance.objetStretch(gain: 0.5); // 쭈욱 당겨오는 쫀득 레이어
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
      _analytics?.gesturePerformed(
          'roll', (e.timeStamp - _rollStartTime).inMilliseconds);
    } else {
      // stroke / none: 굴러가지 않게 vel 부여 없이 grabbed만 해제. 문지르기 이동 함몰은
      // strokeAmp 감쇠(update)에 따라 손을 떼면 서서히 메워진다.
      ball.release();
      if (_dragMode == _DragMode.stroke) {
        _analytics?.gesturePerformed(
            'rub', (e.timeStamp - _strokeStartTime).inMilliseconds);
      }
    }
    _moved = false;
    _dragMode = _DragMode.none;
  }

  /// 포인터 취소(시스템 제스처·창 전환 등): 떼임 이벤트가 안 와도 함몰이 멈춰 있지
  /// 않도록 정리한다. 주 포인터면 상태머신 리셋(무팝), 추가 손가락이면 함몰점 제거.
  void _onPointerCancel(PointerCancelEvent e) {
    final ball = _ball;
    if (ball == null) return;
    _activePointers.remove(e.pointer);
    // 두 손가락 늘리기(GST-05): 쌍 중 하나가 취소되면 스프링백으로 종료.
    if (_stretchActive && (e.pointer == _stretchA || e.pointer == _stretchB)) {
      _endStretch();
    }
    if (e.pointer == _pointerId) {
      _pointerId = null;
      ball.pressCancel();
      ball.release();
      _moved = false;
      _dragMode = _DragMode.none;
    } else {
      ball.extraPressCancel(e.pointer);
    }
  }

  // ── 두 손가락 늘리기(GST-05) 헬퍼 ───────────────────────────────────
  /// 둘째 손가락([secondId])이 공 위에 내려왔을 때, 주 포인터도 공 위면 스트레치
  /// 진입. 두 손가락의 현재 좌표로 ball.stretchStart를 호출한다. 함몰점(주 포인터
  /// 누르기 + 둘째 extraPress)은 건드리지 않아 함몰 + 늘림이 동시에 보인다(결정 ①).
  void _maybeStartStretch(int secondId, Duration timeStamp) {
    final ball = _ball;
    if (ball == null || _stretchActive) return;
    final primaryId = _pointerId;
    if (primaryId == null) return;
    final pa = _activePointers[primaryId];
    final pb = _activePointers[secondId];
    if (pa == null || pb == null) return;
    // 두 손가락이 모두 공 위일 때만 늘리기 진입(단일 포인터 제스처와 비간섭).
    if (!ball.hitTest(pa) || !ball.hitTest(pb)) return;
    _stretchA = primaryId;
    _stretchB = secondId;
    _stretchActive = true;
    _lastStretchSoundAlong = 1.0;
    _stretchStartTime = timeStamp; // 분석용 지속시간 시작점
    _stretchPeakAlong = 1.0; // 최대 늘림 추적 리셋
    // primary가 굴리기/쓰다듬기 중이었으면 그 상태를 중립으로 끊는다 — 잔여 roll
    // 상태로 떼는 순간 엉뚱한 fling이 나가거나 grabbed로 물리가 얼지 않도록.
    // (누르기 함몰 _curDepth는 건드리지 않아 함몰은 유지된다 — 결정 ①.)
    _moved = false;
    _dragMode = _DragMode.none;
    _rollCatchup = 0;
    ball.release();
    RitualAudio.instance.stopRub();
    ball.stretchStart(pa, pb);
    Haptics.instance.fire(HapticLevel.light);
    RitualAudio.instance.objetStretch(gain: 0.6); // 떡 늘어나는 쫀득 레이어
  }

  /// 스트레치 중 두 손가락의 현재 좌표로 늘림 세기·축을 갱신한다.
  /// along 스케일이 일정량 변할 때만 쫀득 사운드를 1발씩 깐다(내장 throttle + 델타 게이트).
  void _updateStretch() {
    final ball = _ball;
    if (ball == null || !_stretchActive) return;
    final a = _stretchA, b = _stretchB;
    if (a == null || b == null) return;
    final pa = _activePointers[a];
    final pb = _activePointers[b];
    if (pa == null || pb == null) return;
    ball.stretchUpdate(pa, pb);
    // 분석용: 제스처 중 도달한 최대 늘림(along) 추적.
    if (ball.stretchAlong > _stretchPeakAlong) _stretchPeakAlong = ball.stretchAlong;
    if ((ball.stretchAlong - _lastStretchSoundAlong).abs() > 0.06) {
      _lastStretchSoundAlong = ball.stretchAlong;
      RitualAudio.instance.objetStretch(gain: 0.45);
    }
  }

  /// 스트레치 종료 — ball.stretchEnd로 쫀득 통통 스프링백을 시작하고 라우팅 상태를 리셋.
  void _endStretch() {
    _ball?.stretchEnd();
    _stretchActive = false;
    _stretchA = null;
    _stretchB = null;
    Haptics.instance.pressRelease();
    RitualAudio.instance.objetSquelch();
  }

  void _goToWriting() {
    // 복귀 시(글쓰기 취소/뒤로) 홈을 멘트 화면으로 복원(§6 보강). 카운트 증가는
    // 의식 완료 감지(_onSessionChanged)에서만 일어나므로 여기선 UI만 초기화.
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const WritingScreen()))
        .then((_) => _restoreHomeInitial());
  }

  /// #1 백그라운드 진입 시 흔들기 가속도 센서 구독을 끊어, 앱을 꺼도 폰을 흔들면
  /// 공이 반응하거나 진동이 나지 않게 한다(오디오·진동 정지는 app.dart가 전역 처리).
  /// 포그라운드 복귀 시 다시 구독한다. 손 떨림 누적도 함께 정리한다.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _accelSub?.cancel();
      _accelSub = null;
      _shakeEndTimer?.cancel();
      RitualAudio.instance.stopRub(); // 문지르기 루프가 떠 있으면 정지
    } else if (state == AppLifecycleState.resumed) {
      if (_accelSub == null) _listenSensors(); // 흔들기 센서 재구독
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session?.removeListener(_onSessionChanged);
    _ticker.dispose();
    _accelSub?.cancel();
    _shakeEndTimer?.cancel(); // 흔들기 사이클 디바운스 타이머 정리
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // §2/§B 소비: 홈만 motion의 SkyBackground로 감싼다(시간대 morph 배경).
    // 글자색은 motion이 제공하는 계약 `skyTextColorAt(DateTime.now())`(현재 시각
    // 보간된 --on-bg)로 결정한다. 기존 dark/light 분기는 이걸로 대체(가독성).
    final Color onBg = skyTextColorAt(DateTime.now());
    // 멘트: 가장 또렷하게(opacity 0.9 느낌).
    final Color msgColor = onBg.withValues(alpha: 0.90);
    // 날짜/힌트 등 보조: 살짝 투명.
    final Color subColor = onBg.withValues(alpha: 0.72);
    // 카운트: 저대비(공 경험 방해 금지, §4)이되, 밝은 파스텔 배경에 묻혀 안 보이던
    // 문제(사용자 피드백 2026-06-08)로 알파를 0.55→0.80으로 올리고 아래 Text에
    // 부드러운 그림자를 더해 어느 그라데이션 위에서도 읽히게 한다.
    final Color countColor = onBg.withValues(alpha: 0.80);
    // 카운트 텍스트 가독용 부드러운 그림자(밝은 배경=대비 확보, 어두운 배경=무해).
    // onBg 반대 휘도 쪽으로 은은히: 글자가 밝으면 어두운 헤일로가 떠받쳐 또렷해진다.
    final List<Shadow> countShadows = [
      Shadow(
        color: Colors.black.withValues(alpha: 0.28),
        blurRadius: 8,
        offset: const Offset(0, 1),
      ),
    ];
    // 도움말 시트는 기존 tone enum 계약을 그대로 쓴다(호환 유지).
    final SkyTone tone = skyToneAt(DateTime.now());
    final bool dark = tone == SkyTone.dark;
    // 도움말 `?` 버튼 전경/배경.
    final Color helpFg = onBg.withValues(alpha: 0.85);
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
              // 멘트를 '공 바로 위 중앙'에 두기 위한 좌표 계산(§C-1).
              // 공은 화면 중앙(rect.center)에 있고 반경은 _ball.radius. 멘트 박스는
              // 사라져도 공이 안 튀게 고정 높이(_kMsgBoxH)로 예약하고, 그 박스의
              // 멘트는 화면 상단부(공보다 한참 위)에 둔다(프로토타입 레이아웃).
              double msgBoxTop = rect.height * 0.12;
              if (msgBoxTop < _kMsgBoxMinTop) msgBoxTop = _kMsgBoxMinTop;
              // 멘트를 두 줄로 분리 — 첫 줄 크게, 둘째 줄 작게.
              final int msgIdx = _releaseCount % homeMessages.length;
              final List<String> msgParts = homeMessages[msgIdx].split('\n');
              final String msgLine1 = msgParts.isNotEmpty ? msgParts[0] : '';
              final String msgLine2 = msgParts.length > 1 ? msgParts[1] : '';
              // 둘째(작은) 줄: '오늘, 처음 흘려보낼까요'는 오늘 첫 실행에만(하루 한 번)
              // 보여준다. 같은 날 재실행이거나 한 번이라도 흘려보냈으면 멘트 원래
              // 둘째 줄. ('N번째 흘려보냄'은 3줄째.)
              final String secondLine =
                  (_showDailyGreeting && _releaseCount == 0)
                      ? '오늘, 처음 흘려보낼까요'
                      : msgLine2;
              return Stack(
                children: [
                  // 공 + 물결 캔버스 + 포인터
                  Positioned.fill(
                    child: Listener(
                      onPointerDown: _onPointerDown,
                      onPointerMove: _onPointerMove,
                      onPointerUp: _onPointerUp,
                      onPointerCancel: _onPointerCancel,
                      behavior: HitTestBehavior.opaque,
                      child: CustomPaint(
                        painter: _ballShader != null
                            ? EmotionBallShaderPainter(
                                ball: _ball!,
                                shader: _ballShader!,
                                ripples: _ripples,
                                repaint: _frame,
                              )
                            : EmotionBallPainter(
                                ball: _ball!,
                                ripples: _ripples,
                                strokeEnergy: _strokeEnergy,
                                repaint: _frame,
                              ),
                      ),
                    ),
                  ),

                  // 날짜(§C-2): 상단 중앙, 작게·살짝 투명. 프로토타입처럼
                  // 첫 터치 시 멘트와 함께 fade-out 한다(직전 '항상 표시'를 되돌림).
                  Positioned(
                    top: _kDateTop,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: _touched ? 0 : 1,
                        duration: const Duration(milliseconds: 600),
                        curve: Curves.easeOut,
                        child: Text(
                          _formatDateTime(_now),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            color: subColor,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                    ),
                  ),

                  // 멘트/카운트 영역(§C-1,3,4): 공 바로 위 중앙. 고정 높이(_kMsgBoxH)
                  // 박스에 예약해 멘트가 사라져도 공이 안 튄다. untouched는 멘트+
                  // releaseCount, touched는 같은 자리에 interactionCount fade-in.
                  Positioned(
                    top: msgBoxTop,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 멘트 첫 줄 — 크게. 첫 터치 시 fade-out.
                          AnimatedOpacity(
                            opacity: _touched ? 0 : 1,
                            duration: const Duration(milliseconds: 600),
                            curve: Curves.easeOut,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 320),
                              child: Text(
                                _keepAll(msgLine1), // 어절 단위 줄바꿈(단어 안 쪼개짐)
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 24,
                                  color: msgColor,
                                  height: 1.4,
                                  letterSpacing: 0.2,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          // 둘째 줄 자리 ↔ interaction 카운트(같은 위치 cross-fade).
                          // 멘트가 사라지면 그 '둘째 줄 자리'에 interaction이 뜬다(§사용자 지시).
                          Stack(
                            alignment: Alignment.topCenter,
                            children: [
                              AnimatedOpacity(
                                opacity: _touched ? 0 : 1,
                                duration: const Duration(milliseconds: 600),
                                curve: Curves.easeOut,
                                child: ConstrainedBox(
                                  constraints:
                                      const BoxConstraints(maxWidth: 300),
                                  child: Text(
                                    _keepAll(secondLine), // 어절 단위 줄바꿈
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: subColor,
                                      height: 1.5,
                                      letterSpacing: 0.2,
                                    ),
                                  ),
                                ),
                              ),
                              AnimatedOpacity(
                                opacity: _touched ? 1 : 0,
                                duration: const Duration(milliseconds: 700),
                                curve: Curves.easeOut,
                                child: Text(
                                  '$_interactionCount interactions',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: countColor,
                                    letterSpacing: 0.4,
                                    shadows: countShadows,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          // 3번째 줄(작게·은은히): 한 번이라도 흘려보냈으면 'N번째
                          // 흘려보냄'. 아직이면 둘째 줄이 '오늘, 처음 흘려보낼까요'이므로
                          // 3줄째는 생략한다. 첫 터치 시 fade-out.
                          if (_releaseCount > 0) ...[
                            const SizedBox(height: 8),
                            AnimatedOpacity(
                              opacity: _touched ? 0 : 1,
                              duration: const Duration(milliseconds: 600),
                              curve: Curves.easeOut,
                              child: Text(
                                '$_releaseCount번째 흘려보냄',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: countColor,
                                  letterSpacing: 0.4,
                                  shadows: countShadows,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),

                  // 하단 힌트(§C-5): 터치 전 "감정말랑이를 마음껏 만져보세요"를
                  // 은은하게(opacity≈0.6). 첫 터치 시 fade-out. '바로 글쓰기' 버튼·
                  // 도움말 ? 버튼과 공존(아래 버튼 위에 띄운다).
                  Positioned(
                    bottom: _kHintBottom,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: _touched ? 0 : 0.6,
                        duration: const Duration(milliseconds: 500),
                        curve: Curves.easeOut,
                        child: Text(
                          '감정말랑이를 마음껏 만져보세요',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            color: onBg,
                            letterSpacing: 0.2,
                          ),
                        ),
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
                        // 시간대 배경은 위는 어둡고 아래는 밝은 그라데이션이라, 하단의
                        // 밝은 노을·크림색에 글씨가 묻혔다. 반투명 프로스트 알약 배경 +
                        // 어두운 글씨로 어느 시간대에서도 항상 읽히게 한다.
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFF5A4651),
                          backgroundColor: Colors.white.withValues(alpha: 0.5),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 18, vertical: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24),
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
