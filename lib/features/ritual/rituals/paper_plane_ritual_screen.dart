import 'dart:math';

import 'package:flutter/material.dart';

import '../../../core/haptics.dart';
import '../../../core/ritual_audio.dart';
import '../../../core/strings.dart';
import '../../../state/analytics_scope.dart';
import '../../../state/session.dart';
import '../../../theme/app_theme.dart';
import '../widgets/paper_card.dart';
import '../widgets/paper_plane_glyph.dart';

// ── 종이비행기 상태머신 ────────────────────────────────────────────────────
/// idle → folding(레퍼런스 4단계 자동 접기) → folded(던지기 대기) →
/// flying(글라이드) → done(인플레이스 완료 멘트→버튼). 라우트 전환 없음(태우기).
enum _Phase { idle, folding, folded, flying, done }

/// 접기 시퀀스 총 길이(레퍼런스 4구간: ① 윗 모서리→중앙 삼각 코 ② 삼각 코를
/// 아래로 접어 뭉툭 ③ 세로 중앙 반접기 ④ 양 날개 아래로). 단계가 하나 늘어
/// 살짝 길게 잡아 각 "탁" 눌림이 또렷이 읽히게 한다.
const Duration _kFoldDuration = Duration(milliseconds: 1900);

/// 비행 글라이드 길이(또렷한 궤적을 그리며 먼 하늘로 후퇴 — 최소 3.8초 보장).
/// 길게 잡아 궤적이 충분히 펼쳐지고, 막판 원근 축소가 '머얼리' 사라지게 한다.
const Duration _kFlyDuration = Duration(milliseconds: 4000);

// (기하 모핑: 사각 종이 외곽 path가 progress로 레퍼런스 4단계 순서를 따라
//  글라이더 외곽 path까지 연속 보간된다. crossfade 팝 제거 — progress=1에서
//  PaperPlaneGlyph 글라이더와 정확히 일치하므로 folded 진입 시 글리프로
//  교체해도 팝이 없다 — _FoldMorphPainter 참조.)

// ── 인플레이스 완료 타임라인(다트 소멸=0 기준) — 태우기와 톤 일치 ──────────
/// 다트가 사라진 뒤 멘트가 뜨기 전 여운(비행기는 잔향 없으니 짧게).
const Duration _kMessageDelay = Duration(milliseconds: 900);

/// 멘트 페이드인(opacity 0→1).
const Duration _kMessageFade = Duration(milliseconds: 1400);

/// done 진입 시 하늘 배경 페이드인(어두운 AppBackground → 평온한 하늘).
/// '비행기가 솟아 사라진 뒤 사용자가 하늘 속으로 올라가 떠 있게 된' 메타포.
const Duration _kSkyFadeIn = Duration(milliseconds: 1800);

/// 두둥실 드리프트 1주기(아주 느린 상하 부유 = 무중력감). 길게 잡아 평온히.
const Duration _kSkyDrift = Duration(seconds: 20);

/// 멘트 뜬 뒤 '처음으로' 버튼까지(= 900 + 1300).
const Duration _kButtonDelay = Duration(milliseconds: 2200);

/// 버튼 페이드인.
const Duration _kButtonFade = Duration(milliseconds: 800);

// ── 접기 크리스 햅틱 발사 지점(진행도) — 레퍼런스 4단계 ─────────────────────
// 각 구간이 닫히는 끝 직전(손을 눌러 자국내는 호흡)에 1발씩.
//   ① 삼각 코     (light)
//   ② 코 아래로 접어 뭉툭(light)
//   ③ 세로 반접기  (light)
//   ④ 날개 아래로  (medium — 마지막 날개접기가 가장 단단, throttle 무시)
// 4구간 균등 경계(0.25/0.50/0.75/1.00) 직전에 배치.
const double _kCreaseNose = 0.23; // ① 삼각 코 닫힘.
const double _kCreaseBlunt = 0.48; // ② 코 아래로 접어 뭉툭.
const double _kCreaseHalf = 0.73; // ③ 세로 반접기.
const double _kCreaseWings = 0.97; // ④ 날개 아래로(단단).

// ── 종이 / 다트 표시 크기 ──────────────────────────────────────────────────
const double _kPaperW = 240;
const double _kPaperH = 320;
const double _kGlyphSize = 200; // 접힌 다트 표시 크기(종이와 시각 균형).

// ── 슬링샷(draw-back) 발사 물리 상수 ───────────────────────────────────────
/// 약투 무시 임계(당긴 거리 px). 이하면 발사 안 함 → 스프링으로 제자리 복귀.
const double _kDrawMin = 46;
/// 세기 정규화 분모(이 거리만큼 당기면 최대 세기). drawDist - min 기준.
const double _kDrawSpan = 230;
/// draw-back 시각 이동 상한(비행기가 손가락 따라 내려가는 최대 px). 화면 밖 방지.
const double _kDrawVisualMax = 150;
/// draw 벡터의 보조 혼합용 던지기 속도 정규화 분모(놓는 손짓 속도 가미).
const double _kFlickSpan = 2600;
/// 발사 기본 상향 바이어스(거의 수직으로 당겨도 위 하늘로 솟게). 0~1.
const double _kUpwardBias = 0.55;

// done 하늘 씬: 하늘 그라데이션·햇무리 제거(사용자 요청) — 원래 다크 배경 위에
// 구름만 천천히 떠다닌다(그라데이션/햇무리 색 상수도 함께 제거).

/// RIT-09 종이비행기. 종이를 레퍼런스 4단계(삼각 코→코 아래로 접어 뭉툭→세로
/// 반접기→날개)로 실제 접어(크리스 햅틱) 글라이더를 만든 뒤, 슬링샷처럼 **눌러
/// 몸 쪽(아래)으로 당겼다 놓으면**(draw-back) 당긴 반대인 위 하늘로 솟아 구름
/// 사이를 가르며 날아간다. 비행 후 같은 화면에 인플레이스 완료.
class PaperPlaneRitualScreen extends StatefulWidget {
  const PaperPlaneRitualScreen({super.key});

  @override
  State<PaperPlaneRitualScreen> createState() => _PaperPlaneRitualScreenState();
}

class _PaperPlaneRitualScreenState extends State<PaperPlaneRitualScreen>
    with TickerProviderStateMixin {
  _Phase _phase = _Phase.idle;

  // 접기 컨트롤러(0→1, 3구간 매핑). bounded.
  late final AnimationController _fold;
  // 비행 컨트롤러(0→1). bounded.
  late final AnimationController _fly;
  // 구름 흩어짐 컨트롤러(done 진입 후 0→1, 잔향 구름이 옅어지며 흩어짐). bounded.
  late final AnimationController _cloudFade;
  // 흔들림 위상 컨트롤러(0→1을 빠르게 반복 = sin 떨림 위상). bounded(repeat).
  //  드래그(당기는) 동안에만 repeat, 놓으면 stop+reset. unbounded 미사용.
  late final AnimationController _wobble;
  // 약투(거의 안 당김) 시 draw-back 위치 → 제자리로 튕겨 돌아가는 스프링. bounded.
  //  0→1로 elasticOut 진행하며 _drawOffset를 시작값에서 0으로 보간(_recoilFrom).
  late final AnimationController _recoil;
  // done 하늘 씬: 어두운 배경 위로 하늘 그라데이션이 페이드인(0→1). bounded forward.
  late final AnimationController _skyFade;
  // done 하늘 씬: 구름 패럴랙스 흐름 + 두둥실 드리프트 위상(0→1 느린 repeat reverse).
  //  bounded controller에 repeat(reverse:true) — unbounded()..repeat() 아님.
  late final AnimationController _skyDrift;
  // 하늘 구름 결정적 시드(재현성). 비행 경로 구름과 다른 시드로 별도 배치.
  static const int _skyCloudSeed = 20260602;
  // 구름 퍼프 결정적 시드(재현성).
  static const int _cloudSeed = 20260601;
  // 천천히 멀어지는 느낌(easeInOutSine): 부드럽게 출발해 일정히 나아가며
  //  후반에 급정거 없이 먼 하늘로 빠져나간다(easeOutCubic처럼 막판 정지하지 않음).
  late final Animation<double> _flyCurve =
      CurvedAnimation(parent: _fly, curve: Curves.easeInOutSine);

  // 접기 크리스 햅틱 fired-set 가드(playTimeline 대신 직접 fire).
  final Set<int> _firedCrease = {};

  // 던지기 결과.
  Offset _flyDir = const Offset(1, -1); // 진행 방향 단위벡터.
  double _flySpeed = 0; // 0~1 → 비행 거리.
  double _flyAngle = 0; // 다트 코를 진행 방향으로 정렬한 각.

  // 비행 중 연속 '진공' 햅틱 핸들(던지는 순간 시작 → 완료/dispose에서 stop).
  // sensory-haptics가 haptics.dart에 추가하는 startFlightHum()/FlightHandle 사용.
  FlightHandle? _flightHandle;

  // done 하늘 씬 동안 지속되는 '두둥실' 연속 햅틱 핸들(하늘에 떠 있는 부유감).
  //  done 진입 시 시작 → '처음으로' 탭/dispose에서 stop. (보석함 heartbeat 패턴.)
  //  sensory-haptics가 haptics.dart에 추가하는 startSkyFloat()/SkyFloatHandle 사용.
  SkyFloatHandle? _skyFloat;

  // 당기는 동안 '긴장감' 피드백 누적(folded에서 드래그 시). 끌수록 틱이 촘촘·세짐.
  double _pullAccum = 0; // 마지막 틱 이후 끈 거리(틱 간격 판정).
  double _pullTotal = 0; // 총 끈 거리(긴장 강도 판정).
  // 당기는 중 플래그(folded 드래그 동안 true). 흔들림 Transform 게이트.
  bool _pulling = false;

  // ── 슬링샷 draw-back ──
  // 손가락 따라 당겨진 비행기의 시각 이동(장전 위치). 주로 아래(+dy)로 쌓인다.
  //  발사 방향 = 이 벡터의 반대, 세기 = 이 벡터 길이.
  Offset _drawOffset = Offset.zero;
  // 약투 복귀 스프링이 시작될 때의 draw 위치(elasticOut으로 0까지 보간).
  Offset _recoilFrom = Offset.zero;

  // 인플레이스 완료 토글.
  bool _showMessage = false;
  bool _showButton = false;

  @override
  void initState() {
    super.initState();
    _fold = AnimationController(vsync: this, duration: _kFoldDuration)
      ..addListener(_onFoldTick)
      ..addStatusListener(_onFoldStatus);
    _fly = AnimationController(vsync: this, duration: _kFlyDuration)
      ..addStatusListener(_onFlyStatus);
    // 잔향 구름 흩어짐: done 진입 후 천천히(완료 멘트와 겹치지 않게 은은히).
    _cloudFade =
        AnimationController(vsync: this, duration: const Duration(seconds: 3));
    // 흔들림 위상: 짧은 주기(120ms)로 0→1 반복 = 빠른 떨림. 값은 sin 위상으로만 사용.
    //  bounded controller에 repeat() — unbounded()..repeat() 아님.
    _wobble = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );
    // 약투 복귀 스프링: 짧고 탄성있게 제자리로(elasticOut으로 살짝 오버슈트).
    _recoil = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 620),
    )..addListener(_onRecoilTick);
    // done 하늘 페이드인: 1회 forward(0→1). done 진입 시 forward(from:0).
    _skyFade = AnimationController(vsync: this, duration: _kSkyFadeIn);
    // 두둥실 드리프트: 아주 느린 0→1 왕복(상하 부유 + 구름 흐름 위상).
    //  done 진입 시 repeat(reverse:true) 시작 → dispose에서 정지.
    _skyDrift = AnimationController(vsync: this, duration: _kSkyDrift);
  }

  // 약투 복귀: _recoilFrom → 0으로 elasticOut 보간(살짝 튕기며 제자리).
  void _onRecoilTick() {
    if (!mounted) return;
    final e = Curves.elasticOut.transform(_recoil.value);
    setState(() => _drawOffset = _recoilFrom * (1 - e));
  }

  // ── 접기: 크리스 햅틱(직접 fire, fired-set 가드) — 레퍼런스 4단계 ─────────
  void _onFoldTick() {
    final t = _fold.value;
    // ① 삼각 코(light) ② 코 아래로 접어 뭉툭(light) ③ 세로 반접기(light)
    // ④ 날개 아래로(medium, 가장 단단). 각 접힘이 닫히는 순간 1발씩.
    if (t >= _kCreaseNose && _firedCrease.add(0)) {
      Haptics.instance.fire(HapticLevel.light);
    }
    if (t >= _kCreaseBlunt && _firedCrease.add(1)) {
      Haptics.instance.fire(HapticLevel.light);
    }
    if (t >= _kCreaseHalf && _firedCrease.add(2)) {
      Haptics.instance.fire(HapticLevel.light);
    }
    if (t >= _kCreaseWings && _firedCrease.add(3)) {
      Haptics.instance.fire(HapticLevel.medium, throttle: false);
    }
    setState(() {}); // 접기 변형 갱신.
  }

  void _onFoldStatus(AnimationStatus s) {
    if (s == AnimationStatus.completed && _phase == _Phase.folding) {
      // 효과음: 접기 끝나면 종이 접힘음 정지 — 발사 전(당겼다 놓기까지)은 무음.
      RitualAudio.instance.stopShot();
      setState(() => _phase = _Phase.folded);
    }
  }

  void _onFlyStatus(AnimationStatus s) {
    if (s == AnimationStatus.completed && _phase == _Phase.flying) {
      _complete();
    }
  }

  // ── 접기 시작(버튼/탭) → 자동 4단계(레퍼런스 순서) ───────────────────────
  void _startFold() {
    if (_phase != _Phase.idle) return;
    _firedCrease.clear();
    // 효과음: 접기 시작 — paper.mp3 원샷(프로토타입 eT 그대로, volume 1.0).
    RitualAudio.instance.paper();
    setState(() => _phase = _Phase.folding); // float:false 전환(접기와 충돌 방지).
    _fold.forward(from: 0);
  }

  // ── 당기는 동안 긴장감 피드백(folded 드래그) ─────────────────────────────
  // 활시위를 당기듯, 끌수록 틱이 촘촘하고 살짝 세진다(약한 긴장감). 발사 전 빌드업.
  void _onPullStart(DragStartDetails d) {
    if (_phase != _Phase.folded) return;
    _pullAccum = 0;
    _pullTotal = 0;
    _recoil.stop(); // 이전 약투 복귀 스프링이 돌고 있으면 중단(잡는 순간 재장전).
    _drawOffset = Offset.zero; // 새 장전 시작점.
    // 잡는 순간부터 다트가 흔들흔들(활시위 긴장). bounded controller repeat.
    _pulling = true;
    _wobble.repeat(); // 0→1 짧은 주기 반복 = sin 떨림 위상.
    setState(() {}); // _buildObject folded 분기가 흔들림 Transform을 그리도록.
    Haptics.instance.fire(HapticLevel.selection); // 잡는 순간 미세한 신호.
  }

  void _onPullUpdate(DragUpdateDetails d) {
    if (_phase != _Phase.folded) return;
    // ── draw-back 누적: 손가락 따라 비행기를 당긴다 ──
    // 주로 아래(몸 쪽, +dy)로 당기는 의도. 위로 미는 성분(-dy)은 절반만 반영해
    //  '아래로 장전' 느낌을 유지(위로 밀어 발사를 약화시키는 역장전 방지).
    var delta = d.delta;
    if (delta.dy < 0) delta = Offset(delta.dx, delta.dy * 0.5);
    var next = _drawOffset + delta;
    // 시각 이동 상한(화면 밖으로 끌려나가지 않게). 길이만 클램프(방향 유지).
    if (next.distance > _kDrawVisualMax) {
      next = next / next.distance * _kDrawVisualMax;
    }
    _drawOffset = next;

    final step = d.delta.distance;
    _pullAccum += step;
    _pullTotal += step;
    // 끌수록 틱 간격이 16px→8px로 좁아진다(긴장 빌드업).
    final tickStep = (16.0 - (_pullTotal / 40).clamp(0.0, 8.0));
    if (_pullAccum >= tickStep) {
      _pullAccum = 0;
      // 약한 긴장감: 초반 selection(아주 미세) → 더 당기면 light로 살짝 세짐.
      Haptics.instance
          .fire(_pullTotal < 110 ? HapticLevel.selection : HapticLevel.light);
    }
    setState(() {}); // draw-back 이동 + 긴장 진폭을 매 프레임 갱신.
  }

  // 흔들림 종료(놓음/취소): repeat 정지 + 위상 리셋. 손을 떼면 더는 떨지 않음.
  void _stopWobble() {
    if (!_pulling) return;
    _pulling = false;
    _wobble.stop();
    _wobble.value = 0; // 다음 당김을 위해 위상 리셋(잔류 떨림 0).
  }

  // 드래그 취소(시스템이 제스처를 가로챔 등) — 흔들림 정리 + 제자리로 복귀.
  void _onPullCancel() {
    if (_phase != _Phase.folded) return;
    _stopWobble();
    _springBack(); // 장전된 위치에서 제자리로 튕겨 복귀.
  }

  // 약투/취소 시 draw-back 위치에서 제자리(Offset.zero)로 탄성 복귀.
  void _springBack() {
    if (_drawOffset == Offset.zero) {
      setState(() {}); // 이미 제자리 — 정지 다트로 환원.
      return;
    }
    _recoilFrom = _drawOffset;
    _recoil.forward(from: 0); // elasticOut으로 0까지 보간(_onRecoilTick).
  }

  // ── 슬링샷 발사(release) — onPanEnd ───────────────────────────────────────
  // 당긴 반대 방향(주로 위 하늘)으로, 당긴 거리에 비례한 세기로 솟아 발사한다.
  void _throw(DragEndDetails d) {
    if (_phase != _Phase.folded) return;
    // 놓는 순간 흔들림 종료(장전 긴장 해제).
    _stopWobble();

    final draw = _drawOffset; // 당겨진 벡터(주로 +dy).
    final drawDist = draw.distance;
    // ── 약투: 거의 안 당김 → 발사 무시, 스프링으로 제자리 복귀 ──
    if (drawDist < _kDrawMin) {
      _springBack();
      return; // 발사하지 않음(상태 folded 유지).
    }

    // ── 발사 방향 = draw 벡터의 반대(아래로 당기면 위로) ──
    var launch = -draw / drawDist; // 정규화된 반대 방향.
    // 놓는 손짓 속도를 보조로 가미(휙 놓으면 그 반대로 살짝 더). 미세 혼합.
    final v = d.velocity.pixelsPerSecond;
    final flick = (v.distance / _kFlickSpan).clamp(0.0, 1.0);
    if (v.distance > 1) {
      launch = launch + (-v / v.distance) * flick * 0.6;
      final m = launch.distance;
      if (m > 0) launch = launch / m; // 재정규화.
    }
    // ── 상향 바이어스: 거의 수직으로 당겨도 위 하늘로 솟게 -y 성분 보강 ──
    launch = Offset(launch.dx * (1 - _kUpwardBias),
        launch.dy * (1 - _kUpwardBias) - _kUpwardBias);
    final lm = launch.distance;
    _flyDir = lm > 0 ? launch / lm : const Offset(0, -1);

    // ── 세기 = 당긴 거리 정규화(많이 당길수록 멀리). 발사 임팩트 강도에도 사용 ──
    _flySpeed =
        ((drawDist - _kDrawMin) / _kDrawSpan).clamp(0.0, 1.0);
    // 글리프 코는 -y이므로 진행 방향 정렬 보정각 = atan2 + π/2.
    _flyAngle = atan2(_flyDir.dy, _flyDir.dx) + pi / 2;
    // 발사 임팩트 햅틱: 당긴 세기에 비례(impactBySpeed는 px/s 기대 → 세기 환산).
    Haptics.instance.impactBySpeed(600 + _flySpeed * 1900);
    // 효과음: 발사 순간 — whoosh.wav 원샷(바람 가로지르는 소리). 접기음(paper)과 구분.
    RitualAudio.instance.whoosh();
    // whoosh가 끝나는 즈음(~1.3s) 구름 두둥실 앰비언트를 그라데이션(페이드인)으로 이어줌.
    Future.delayed(const Duration(milliseconds: 1300), () {
      if (!mounted) return;
      RitualAudio.instance.startSky();
    });
    // 발사 직후: 비행 동안 내내 도는 '진공' 연속 햅틱 시작(완료에 stop).
    _flightHandle = Haptics.instance.startFlightHum();
    _drawOffset = Offset.zero; // 발사했으니 장전 위치 해제(비행 Transform이 인계).
    setState(() => _phase = _Phase.flying);
    _fly.forward(from: 0);
  }

  // ── 비행 완료 → 인플레이스 완료 시퀀스(태우기 패턴) ───────────────────────
  void _complete() {
    if (_phase == _Phase.done || !mounted) return;
    // 착지(먼 점이 되어 사라짐) — 비행 연속 햅틱 정지.
    _flightHandle?.stop();
    _flightHandle = null;
    setState(() => _phase = _Phase.done);
    // 비행기는 먼 하늘로 사라짐 — 경로에 피어난 잔향 구름을 천천히 흩어지게.
    _cloudFade.forward(from: 0);
    // ── done 하늘 씬 ──
    // 어두운 AppBackground 위로 평온한 하늘이 페이드인(비행 구름이 잦아드는 동안
    //  하늘 구름이 떠오르며 자연 전환). '하늘로 올라가 그 안에 떠 있게 된' 메타포.
    _skyFade.forward(from: 0);
    _skyDrift.repeat(reverse: true); // 아주 느린 상하 부유 + 구름 흐름 위상.
    // 하늘에 떠 있는 동안 '두둥실' 연속 진동(부유감). 처음으로/dispose에서 stop.
    _skyFloat = Haptics.instance.startSkyFloat(safety: const Duration(minutes: 10));
    // (효과음 앰비언트는 발사 직후 whoosh 끝나는 즈음 이미 페이드인으로 시작됨 —
    //  여기선 재시작하지 않아 끊김 없이 그대로 이어진다.)

    Future.delayed(_kMessageDelay, () {
      if (!mounted) return;
      // 멘트 페이드인 시작 순간 부드러운 완료 햅틱 1회(CompleteScreen 톤).
      Haptics.instance.fire(HapticLevel.success, throttle: false);
      AnalyticsScope.of(context)
        ..ritualCompleted('paperPlane')
        ..completionViewed();
      setState(() => _showMessage = true);
    });
    Future.delayed(_kButtonDelay, () {
      if (!mounted) return;
      setState(() => _showButton = true);
    });
  }

  // ── '처음으로': 세션 리셋 + 홈 복귀(태우기·CompleteScreen과 동일) ──
  void _backToHome() {
    // 하늘에 떠 있는 동안 돌던 '두둥실' 진동 종료(누수/잔향 방지, stop은 idempotent).
    _skyFloat?.stop();
    _skyFloat = null;
    // 효과음: 하늘 앰비언트도 함께 종료.
    RitualAudio.instance.stopSky();
    SessionScope.of(context).reset();
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  void dispose() {
    // 비행 도중 화면 이탈 시 연속 햅틱 누수 방지(stop은 idempotent).
    _flightHandle?.stop();
    _flightHandle = null;
    // done 하늘 씬 진입 후 이탈 시 '두둥실' 연속 햅틱 누수 방지.
    _skyFloat?.stop();
    _skyFloat = null;
    RitualAudio.instance.stopAll();
    _fold
      ..removeListener(_onFoldTick)
      ..removeStatusListener(_onFoldStatus)
      ..dispose();
    _fly
      ..removeStatusListener(_onFlyStatus)
      ..dispose();
    _cloudFade.dispose();
    _wobble.dispose();
    _recoil
      ..removeListener(_onRecoilTick)
      ..dispose();
    _skyFade.dispose();
    _skyDrift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = SessionScope.of(context).text;
    final folding = _phase == _Phase.folding;
    // idle/folding엔 종이를 탭하면 접기 시작(버튼 외 추가 트리거).
    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Stack(
            children: [
              // ── 중앙 오브제(접기 종이 ↔ 다트) ──
              Center(
                child: GestureDetector(
                  onTap: _phase == _Phase.idle ? _startFold : null,
                  // folded: 당기는 동안 긴장감 틱 → 놓으면 발사.
                  onPanStart: _phase == _Phase.folded ? _onPullStart : null,
                  onPanUpdate: _phase == _Phase.folded ? _onPullUpdate : null,
                  onPanEnd: _phase == _Phase.folded ? _throw : null,
                  onPanCancel: _phase == _Phase.folded ? _onPullCancel : null,
                  behavior: HitTestBehavior.opaque,
                  child: AnimatedBuilder(
                    // _wobble: folded 당김 중 떨림. _recoil: 약투 복귀 스프링.
                    //  (둘 다 setState로도 갱신되나, 컨트롤러 tick과 동기 보장.)
                    animation:
                        Listenable.merge([_fold, _flyCurve, _wobble, _recoil]),
                    builder: (context, _) => _buildObject(context, text),
                  ),
                ),
              ),

              // ── 구름 레이어(비행 경로 따라 그림책 뭉게구름이 점점이 피어남) ──
              // 비행기를 가리지 않고 경로 주변에 피어나며, 비행기는 그 사이를
              // 지나 멀리 후퇴해 작은 점이 되어 사라진다. flying/done에만 활성.
              if (_phase == _Phase.flying || _phase == _Phase.done)
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedBuilder(
                      animation: Listenable.merge([_flyCurve, _cloudFade]),
                      builder: (context, _) {
                        final size = MediaQuery.of(context).size;
                        return CustomPaint(
                          painter: _CloudFieldPainter(
                            flyT: _flyCurve.value,
                            center: Offset(size.width / 2, size.height / 2),
                            screenSize: size,
                            dir: _flyDir,
                            flySpeed: _flySpeed,
                            dissipate: _cloudFade.value, // done 후 흩어짐(0→1).
                            seed: _cloudSeed,
                          ),
                        );
                      },
                    ),
                  ),
                ),

              // ── done 하늘 씬(평온한 하늘로 페이드 전환) ──
              // 비행기가 솟아 사라진 뒤(done) 어두운 배경 위로 평온한 하늘이
              // 페이드인되고, 여러 겹 구름이 서로 다른 속도로 흘러가며(패럴랙스)
              // 씬 전체가 아주 느린 sin으로 상하 부유한다 → '하늘 위를 두둥실'.
              //  멘트/버튼 레이어는 이 아래 Stack 순서상 위에 그려져 가독성 유지.
              if (_phase == _Phase.done)
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedBuilder(
                      animation: Listenable.merge([_skyFade, _skyDrift]),
                      builder: (context, _) {
                        final size = MediaQuery.of(context).size;
                        // 두둥실 위상(0→2π): _skyDrift 0↔1 왕복을 sin 위상으로.
                        final drift = _skyDrift.value;
                        return Opacity(
                          opacity: Curves.easeInOut.transform(_skyFade.value),
                          child: CustomPaint(
                            size: size,
                            painter: _SkyScenePainter(
                              drift: drift,
                              seed: _skyCloudSeed,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),

              // ── 하단 안내/버튼 ──
              Positioned(
                left: 0,
                right: 0,
                bottom: 44,
                child: IgnorePointer(
                  ignoring: _phase != _Phase.idle,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 300),
                    opacity: _phase == _Phase.idle
                        ? 1.0
                        : (_phase == _Phase.folded ? 1.0 : 0.0),
                    child: Center(
                      child: _phase == _Phase.folded
                          ? const Text(
                              '비행기를 아래로 당겼다 놓아 하늘로 날려 보내요',
                              style: TextStyle(color: Colors.white60),
                            )
                          : FilledButton.icon(
                              onPressed: folding ? null : _startFold,
                              icon: const PaperPlaneGlyph(size: 18),
                              label: const Text('비행기로 접어요'),
                              style: FilledButton.styleFrom(
                                backgroundColor: AppColors.ballGlow,
                              ),
                            ),
                    ),
                  ),
                ),
              ),

              // ── 완료 멘트(인플레이스 페이드인) ──
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

              // ── '처음으로' 버튼(멘트 뒤 페이드인) ──
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
          ),
        ),
      ),
    );
  }

  // ── 중앙 오브제 빌더: 접기 변형 / 비행 변환 / 크로스페이드 ──────────────────
  Widget _buildObject(BuildContext context, String text) {
    // 비행 변환(flying/done): 던진 방향으로 부드러운 곡선 궤적을 그리며 멀어지고,
    //  원근으로 작아져 먼 점이 되어 사라진다(중반 소멸 금지 — 또렷이 날아간다).
    if (_phase == _Phase.flying || _phase == _Phase.done) {
      final t = _flyCurve.value;
      final size = MediaQuery.of(context).size;
      final offset = _flightOffset(size, _flyDir, _flySpeed, t);
      // 원근 후퇴: 1→0.10까지, 후반 가속 축소(t²의 가중)로 '먼 하늘로' 빨려든다.
      //  ease가 후반부에 더 깊이 줄어 멀어질수록 급격히 작아지는 원근감.
      final shrink = t * (0.55 + t * 0.45); // 0→1, 후반 가속.
      final scale = (1.0 - shrink * 0.90).clamp(0.10, 1.0);
      // opacity는 막판(t>0.85)에만 서서히 0으로 — 중반엔 또렷이 보이며 날아간다.
      final planeOpacity = (1.0 - ((t - 0.85) / 0.15).clamp(0.0, 1.0))
          .clamp(0.0, 1.0);
      return Transform.translate(
        offset: offset,
        child: Transform.rotate(
          angle: _flyAngle,
          child: Transform.scale(
            scale: scale,
            child: Opacity(
              opacity: planeOpacity,
              child: const PaperPlaneGlyph(size: _kGlyphSize, shadow: true),
            ),
          ),
        ),
      );
    }

    // idle: 흩날리는 텍스트 종이.
    if (_phase == _Phase.idle) {
      return const _SizedPaper(float: true);
    }

    // folded: 슬링샷 장전. 당긴 만큼 손가락 따라 이동(_drawOffset) + 장전 긴장
    //  (당기는 동안 흔들흔들 떨림 + 살짝 뒤로 눕고 미세 scale로 '장전감').
    //  당기지 않으면 정지 다트, 약투 후엔 _recoil 스프링으로 제자리 복귀.
    if (_phase == _Phase.folded) {
      const glyph = PaperPlaneGlyph(size: _kGlyphSize, shadow: true);
      // 당긴 거리(0~1, 시각 상한 기준). 장전 scale/tilt 강도.
      final loaded = (_drawOffset.distance / _kDrawVisualMax).clamp(0.0, 1.0);

      // ── 떨림(활시위 긴장): 당기는 동안에만 ──
      double wdx = 0, wdy = 0, wAngle = 0;
      if (_pulling) {
        // 위상: _wobble(0→1)을 2π로. 회전·translate는 살짝 다른 주파수/위상의
        //  sin을 겹쳐 '단조롭지 않게 부르르' 떨리게 한다(paint-only, 레이아웃 무관).
        final phase = _wobble.value * 2 * pi;
        // 당긴 정도에 따라 진폭 증가(0→1, 더 당길수록 긴장 ↑). 상한 클램프.
        final tension = (_pullTotal / 160).clamp(0.0, 1.0);
        // 회전 ±2°~±4°(라디안). 기본 2° + 긴장 2°.
        final angAmp = (2.0 + tension * 2.0) * pi / 180;
        wAngle = sin(phase) * angAmp;
        // 미세 translate ±2~3px(회전과 다른 위상/주파수로 떨림이 섞이게).
        final tAmp = 2.0 + tension * 1.0; // 2~3px.
        wdx = sin(phase * 1.7 + 0.6) * tAmp;
        wdy = cos(phase * 1.3) * tAmp;
      }

      // 장전 위치 이동(_drawOffset) + 떨림 + 미세 scale(눌리는 장전감) + 뒤로 눕기.
      //  뒤로 눕기: 당긴 반대(발사) 방향을 코가 살짝 향하도록 미세 회전(±5°).
      final loadScale = 1.0 - loaded * 0.06; // 당길수록 살짝 작아짐(장전 압축).
      // 발사 방향(=당김 반대)으로 코를 살짝 기울임. 거의 수직 당김이면 0에 수렴.
      final tiltSign = _drawOffset.dx == 0 ? 0.0 : -_drawOffset.dx.sign;
      final loadTilt = tiltSign * loaded * (5 * pi / 180);

      if (_drawOffset == Offset.zero && !_pulling) return glyph;
      return Transform.translate(
        offset: _drawOffset + Offset(wdx, wdy),
        child: Transform.rotate(
          angle: wAngle + loadTilt,
          child: Transform.scale(
            scale: loadScale,
            child: glyph,
          ),
        ),
      );
    }

    // folding: 레퍼런스 4단계 기하 모핑(끝이 글리프와 정확히 일치 — 크로스페이드 없음).
    return _FoldingPaper(progress: _fold.value, text: text);
  }
}

/// 접기 전/후 공통 종이 박스(고정 크기). float만 토글.
class _SizedPaper extends StatelessWidget {
  const _SizedPaper({required this.float});
  final bool float;

  @override
  Widget build(BuildContext context) {
    final text = SessionScope.of(context).text;
    return PaperCard(
      text: text,
      width: _kPaperW,
      height: _kPaperH,
      float: float,
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// 접기 기하 모핑 위젯(crossfade 팝 제거): 단일 CustomPaint로 사각 종이의
// 외곽·면·크리스선 자체를 progress(0→1)로 **레퍼런스 4단계** 순서대로 글라이더
// 비행기까지 **연속 보간**한다(중간 크로스페이드/팝 없음).
//   ① 삼각 코      (0.00–0.25): 윗 양 모서리가 중앙선으로 접혀 내려와 큰 삼각
//      코를 형성. 상단 실루엣이 평평한 윗변 → 한 점(꼭지)으로 수렴(삼각 플랩 음영).
//   ② 코 아래로(뭉툭)(0.25–0.50): 삼각의 꼭지(맨 위 점)를 아래로 접어 내려,
//      상단이 한 점 → **짧은 수평 단면(뭉툭한 코)** 으로 펼쳐진다. 접어 내린
//      머리 자국이 사다리꼴 음영으로 남는다. ← 레퍼런스의 핵심 단계.
//   ③ 세로 반접기  (0.50–0.75): 가운데 세로 능선(keel)이 또렷해지고 폭이 살짝
//      좁아지며 우측 반이 그늘져 '접힌 V자' 단면이 시작된다.
//   ④ 날개 아래로  (0.75–1.00): 좌우 바깥 아래변이 넓은 날개 뒷전으로 펼쳐지고
//      꼬리 노치·keel V홈이 파이며 전체가 **넓적한 글라이더**로 수렴.
//   progress=1 외곽 = PaperPlaneDartGeometry(글리프와 동일 비율) → folded 진입
//   시 글리프로 교체해도 팝 없음.
//   텍스트: 사각 종이엔 보이고, ① 삼각 코 접힘부터 접힌 면에 덮여 페이드아웃.
// ════════════════════════════════════════════════════════════════════════
class _FoldingPaper extends StatelessWidget {
  const _FoldingPaper({required this.progress, required this.text});

  final double progress; // 0→1.
  final String text;

  @override
  Widget build(BuildContext context) {
    // 텍스트 페이드: 사각 종이(progress~0)엔 또렷, ① 삼각 코 접힘(0.12~0.24)에서
    // 접힌 면에 덮여 자연스럽게 사라진다(갑작스런 toggle 금지 — 부드러운 페이드).
    final textOpacity =
        (1.0 - ((progress - 0.12) / 0.12)).clamp(0.0, 1.0);

    return SizedBox(
      width: _kPaperW,
      height: _kPaperH,
      // 기하 모핑 페인터: 사각 → 글라이더 외곽/면/크리스 + 텍스트(클립)를 한 번에.
      child: CustomPaint(
        size: const Size(_kPaperW, _kPaperH),
        painter: _FoldMorphPainter(
          progress: progress,
          text: text,
          textOpacity: textOpacity,
        ),
      ),
    );
  }
}

/// 종이 사각형 → 글라이더 기하 모핑 페인터(레퍼런스 4단계).
///
/// 핵심: 외곽 정점을 progress로 단계별 `Offset.lerp` 하여 사각 → 삼각코 →
/// 뭉툭코 → 반접기 → 날개로 **연속 변형**하고, 접힘 면(삼각 코 플랩, 뭉툭 머리
/// 자국, 우측 V면)과 크리스 선(중앙 keel, 코 접힘선, 날개 접힘선)을 단계별로
/// 나타낸다. progress=1 외곽은 `PaperPlaneDartGeometry`(글리프)와 정확히 일치.
class _FoldMorphPainter extends CustomPainter {
  _FoldMorphPainter({
    required this.progress,
    required this.text,
    required this.textOpacity,
  });

  final double progress; // 0→1.
  final String text;
  final double textOpacity;

  // 색(테마 토큰과 동일 값 — 신규 토큰 추가 금지).
  static const Color _paper = AppColors.paper; // 밝은 면.
  static const Color _paperShadow = AppColors.paperShadow; // 그늘 면.
  static const Color _ink = AppColors.ink; // keel·외곽·크리스 선.

  // 4구간 정규화(각 구간 내 0→1, easeInOut으로 단계 경계서 "탁" 눌리는 느낌).
  //   c1: 삼각 코  c2: 코 아래로(뭉툭)  c3: 세로 반접기  c4: 날개 아래로
  static double _seg(double p, double a, double b) =>
      Curves.easeInOut.transform(((p - a) / (b - a)).clamp(0.0, 1.0));

  @override
  void paint(Canvas canvas, Size size) {
    final c1 = _seg(progress, 0.00, 0.25); // ① 삼각 코.
    final c2 = _seg(progress, 0.25, 0.50); // ② 코 아래로(뭉툭).
    final c3 = _seg(progress, 0.50, 0.75); // ③ 세로 반접기.
    final c4 = _seg(progress, 0.75, 1.00); // ④ 날개 아래로.

    // ── 글라이더 타깃 정점(글리프와 동일 비율) ──
    final g = PaperPlaneDartGeometry.forSquare(size);
    final noseMid = g.noseMid; // 뭉툭 코 평평 단면 중점.

    final w = size.width;
    final h = size.height;
    final cx = w / 2;

    // ── 시작 사각형 정점(좌상·우상·우하·좌하) ──
    // ③ 세로 반접기(c3)가 폭을 살짝 좁히므로(능선) 좌우 바깥변을 c3로 미세 수축.
    final squeeze = c3 * w * 0.05;
    final sqTL = Offset(squeeze, 0);
    final sqTR = Offset(w - squeeze, 0);
    final sqBR = Offset(w - squeeze, h);
    final sqBL = Offset(squeeze, h);

    // ── ① 삼각 코: 상단 좌우 모서리가 중앙 꼭지(topApex=(cx,0))로 모인다 ──
    // 상단 두 점을 c1으로 꼭지 쪽으로 끌어당겨 평평한 윗변 → 한 점(삼각) 수렴.
    final topApex = Offset(cx, 0);
    final triL = Offset.lerp(sqTL, topApex, c1)!; // 좌상 → 꼭지.
    final triR = Offset.lerp(sqTR, topApex, c1)!; // 우상 → 꼭지.

    // ── ② 코 아래로(뭉툭): 꼭지(한 점)를 아래로 접어 평평 단면으로 펼친다 ──
    // 상단 외곽이 한 점(topApex) → 짧은 수평 단면(noseL·noseR)으로 c2 보간.
    //  c2=0이면 두 점이 꼭지에 겹쳐 '뾰족', c2=1이면 평평한 뭉툭 코.
    final noseL = Offset.lerp(topApex, g.noseL, c2)!;
    final noseR = Offset.lerp(topApex, g.noseR, c2)!;

    // ── ④ 날개 아래로: 하단 좌우가 넓은 날개 뒷전으로, 꼬리 노치·V홈이 파인다 ──
    final outTailL = Offset.lerp(sqBL, g.tailL, c4)!;
    final outTailR = Offset.lerp(sqBR, g.tailR, c4)!;
    final keelBottom = Offset.lerp(Offset(cx, h), g.keelBottom, c4)!;
    final notchL = Offset.lerp(Offset(cx, h), g.notchL, c4)!;
    final notchR = Offset.lerp(Offset(cx, h), g.notchR, c4)!;

    // ── 외곽 실루엣 path(상단 뭉툭 코 단면 → 하단 좌우 → 꼬리 V) ──
    // 상단은 noseL→noseR 평평 단면, 하단은 c4로 날개 뒷전+꼬리 노치가 차오른다.
    final outline = Path()
      ..moveTo(noseL.dx, noseL.dy)
      ..lineTo(noseR.dx, noseR.dy)
      ..lineTo(outTailR.dx, outTailR.dy)
      ..lineTo(notchR.dx, notchR.dy)
      ..lineTo(keelBottom.dx, keelBottom.dy)
      ..lineTo(notchL.dx, notchL.dy)
      ..lineTo(outTailL.dx, outTailL.dy)
      ..close();

    // ── drop shadow(종이 질감, 살짝) ──
    canvas.drawPath(
      outline.shift(const Offset(0, 7)),
      Paint()
        ..color = const Color(0x33000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
    );

    // ── 본체 채움(밝은 면) ──
    canvas.drawPath(outline, Paint()..color = _paper);

    // ── ③+④ keel 우측 면(그늘): 세로 반접기부터 우측 반이 그늘진 V자 단면 ──
    // c3로 페이드인(반접기), c4로 또렷해지며 날개 뒷전까지 우측 면을 덮는다.
    final rightAlpha = (c3 * (0.5 + 0.5 * c4)).clamp(0.0, 1.0);
    if (rightAlpha > 0.001) {
      final rightFace = Path()
        ..moveTo(noseMid.dx, noseL.dy)
        ..lineTo(noseR.dx, noseR.dy)
        ..lineTo(outTailR.dx, outTailR.dy)
        ..lineTo(notchR.dx, notchR.dy)
        ..lineTo(keelBottom.dx, keelBottom.dy)
        ..close();
      canvas.drawPath(
        rightFace,
        Paint()..color = _paperShadow.withValues(alpha: rightAlpha),
      );
    }

    // ── ① 삼각 코 플랩 음영(좌/우 접힌 삼각면) ──
    // 윗 모서리가 중앙선으로 접혀 내려온 삼각 플랩을 paperShadow로 그늘짐.
    // c1으로 깊어지고, ② 코 아래로(c2)에서 뭉툭 머리 음영에 흡수되며 옅어진다.
    final flapAlpha = (c1 * (1.0 - c2)).clamp(0.0, 1.0);
    if (flapAlpha > 0.001) {
      // 삼각 코의 좌/우 접힘선이 만나는 중앙선상의 아래 끝(c1로 깊어짐).
      final apex = Offset.lerp(Offset(cx, 0), Offset(cx, h * 0.42), c1)!;
      final flapL = Path()
        ..moveTo(topApex.dx, topApex.dy)
        ..lineTo(triL.dx, triL.dy)
        ..lineTo(apex.dx, apex.dy)
        ..close();
      final flapR = Path()
        ..moveTo(topApex.dx, topApex.dy)
        ..lineTo(triR.dx, triR.dy)
        ..lineTo(apex.dx, apex.dy)
        ..close();
      final flapPaint = Paint()
        ..color = _paperShadow.withValues(alpha: 0.7 * flapAlpha);
      canvas.drawPath(flapL, flapPaint);
      canvas.drawPath(flapR, flapPaint);
      final foldLine = Paint()
        ..color = _ink.withValues(alpha: 0.12 * flapAlpha)
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke;
      canvas.drawLine(triL, apex, foldLine);
      canvas.drawLine(triR, apex, foldLine);
    }

    // ── ② 뭉툭 코 머리 자국(삼각 꼭지를 아래로 접어 내린 사다리꼴 음영) ──
    // c2로 나타나(코가 뭉툭해지는 단계), ③/④에서도 남아 무게 실린 머리를 표현.
    // (글리프의 head 음영과 동일 형태/강도(0.55)로 수렴 → progress=1 일치.)
    final headAlpha = c2 * 0.55; // 0→0.55(c2 완료 시 글리프와 동일).
    if (headAlpha > 0.001) {
      final headY = noseL.dy + (keelBottom.dy - noseL.dy) * 0.30;
      final headHalfTop = (noseR.dx - noseL.dx) / 2;
      final headL = Offset(noseL.dx - headHalfTop * 0.70, headY);
      final headR = Offset(noseR.dx + headHalfTop * 0.70, headY);
      final head = Path()
        ..moveTo(noseL.dx, noseL.dy)
        ..lineTo(noseR.dx, noseR.dy)
        ..lineTo(headR.dx, headR.dy)
        ..lineTo(headL.dx, headL.dy)
        ..close();
      canvas.drawPath(
        head,
        Paint()..color = _paperShadow.withValues(alpha: headAlpha),
      );
      // 코 접힘선(평평 단면) — 뭉툭함을 또렷이.
      canvas.drawLine(
        headL,
        headR,
        Paint()
          ..color = _ink.withValues(alpha: 0.10 * c2)
          ..strokeWidth = size.shortestSide * 0.007
          ..strokeCap = StrokeCap.round,
      );
    }

    // ── 텍스트(종이 위 글) — 외곽 path로 클립, textOpacity로 페이드 ──
    if (textOpacity > 0.01 && text.isNotEmpty) {
      canvas.save();
      canvas.clipPath(outline);
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: _ink.withValues(alpha: textOpacity),
            fontSize: 15,
            height: 1.6,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 12,
        ellipsis: '…',
      )..layout(maxWidth: w - 40);
      tp.paint(canvas, const Offset(20, 20));
      canvas.restore();
    }

    // ── 크리스 선들(progress로 나타남) ──
    // ③ 중앙 세로 크리스(반접기 능선): c3로 또렷이. ④ 날개(c4)에서 keel 선이
    //    이를 이어받으므로 c4로 페이드아웃(이중선 방지 — 글리프와 일치).
    final creaseAlpha = (0.18 * (0.5 + 0.5 * c3) * (1.0 - c4)).clamp(0.0, 1.0);
    if (creaseAlpha > 0.001) {
      final topPt = Offset.lerp(Offset(cx, 0), noseMid, c2)!;
      final botPt = Offset.lerp(Offset(cx, h), g.keelBottom, c4)!;
      canvas.drawLine(
        topPt,
        botPt,
        Paint()
          ..color = _ink.withValues(alpha: creaseAlpha)
          ..strokeWidth = size.shortestSide * 0.006
          ..strokeCap = StrokeCap.round,
      );
    }

    // ④ keel 선(동체: 코 중앙→keelBottom) + 날개 접힘선 — 날개 단계에서 또렷.
    if (c4 > 0.001) {
      canvas.drawLine(
        noseMid,
        keelBottom,
        Paint()
          ..color = _ink.withValues(alpha: 0.20 * c4)
          ..strokeWidth = size.shortestSide * 0.012
          ..strokeCap = StrokeCap.round,
      );
      // 날개 접힘선(코→날개 뒷전) — 좌우 바깥변이 keel 기준 접힌 능선.
      final wingFold = Paint()
        ..color = _ink.withValues(alpha: 0.10 * c4)
        ..strokeWidth = size.shortestSide * 0.008
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round;
      canvas.drawLine(noseMid, outTailL, wingFold);
      canvas.drawLine(noseMid, outTailR, wingFold);
    }

    // ── 외곽 미세 stroke(종이 가장자리 암시, ink 10%) — 글리프와 동일 톤 ──
    canvas.drawPath(
      outline,
      Paint()
        ..color = _ink.withValues(alpha: 0.10)
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.shortestSide * 0.008
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _FoldMorphPainter old) =>
      old.progress != progress ||
      old.text != text ||
      old.textOpacity != textOpacity;
}

// ════════════════════════════════════════════════════════════════════════
// 비행 경로 공식(단일 출처): 비행기의 Center(화면중앙) 기준 오프셋.
//   - 비행기 Transform(_buildObject)과 구름 레이어(_CloudFieldPainter)가
//     동일 공식을 호출 → 화면 좌표(중앙+offset)가 두 레이어에서 일치.
//   - dir: 진행 단위벡터, speed: 0~1(거리), t: 비행 진행(곡선 적용 후).
// ════════════════════════════════════════════════════════════════════════
Offset _flightOffset(Size size, Offset dir, double speed, double t) {
  // 거리 상향: 화면을 가로질러 '멀리'(화면 밖) 후퇴 — 먼 점이 되어 사라지게.
  final dist = size.longestSide * (1.0 + speed * 0.8);
  final base = dir * dist * t;
  // 고도감: 던진 직후 살짝 위로 솟았다(상승) 멀리 날아가는 완만한 포물선.
  //  -sin(t·π)은 중반에 최고로 솟았다 가라앉는 대칭형이라 '솟구쳐 멀어짐'이
  //  덜 보인다. 대신 초반에 빨리 솟고(상승) 천천히 잦아드는 비대칭 lift를 쓴다.
  //  진행 방향에 수직(위쪽 성분이 큰)으로 살짝 띄워 부드러운 S 곡선 궤적을 만든다.
  final lift = -sin(t * pi * 0.82) * (70 + speed * 30) * (1 - t * 0.35);
  // 가로 일렁임(고도와 합쳐져 완만한 S): 느린 비행 동안 부드럽게, 말미로 잦아듦.
  final sway = sin(t * pi * 1.3) * 26 * (1 - t);
  // perp: 진행 방향에 수직(화면상 '위쪽' 쪽으로 lift를 얹기 위한 기준).
  final perp = Offset(-dir.dy, dir.dx);
  return base + Offset(sway, lift) + perp * (lift * 0.18);
}

// ════════════════════════════════════════════════════════════════════════
// 구름 레이어: 비행 경로를 따라 '그림책 뭉게구름(cumulus)'이 점점이 피어난다.
//   - 한 덩이 = 여러 둥근 lobe(원호)가 겹친 뭉게구름 실루엣(아래 평평, 위는
//     둥근 봉우리 여러 개) + 부드러운 흰 채움 + 윗면 하이라이트/아랫면 옅은 그늘.
//     외곽은 약한 blur로 soft하되 형태가 구름으로 읽힌다.
//   - 비행기가 궤적을 따라 지나가며 경로 주변에 피어나 천천히 커지고 떠다니다
//     옅어진다. 멀리(후반 emit)의 구름은 작게 그려 원근감. 비행기를 가리지 않고
//     (occlusion 뱅크 제거) 그 사이를 지나 멀리 간다.
//   - 결정적: Random(seed)로 lobe 파라미터 고정(재현성·프레임 점프 0).
//   - 색: 흰색~연한 라벤더(어둡지 않게), painter 로컬 const(테마 토큰 추가 X).
//   - dissipate(0→1, done 후): 잔향 구름이 옅어지며 살짝 위로 흩어짐.
// ════════════════════════════════════════════════════════════════════════
class _CloudFieldPainter extends CustomPainter {
  _CloudFieldPainter({
    required this.flyT,
    required this.center,
    required this.screenSize,
    required this.dir,
    required this.flySpeed,
    required this.dissipate,
    required this.seed,
  });

  final double flyT; // 비행 진행(곡선 후).
  final Offset center; // 화면 중앙.
  final Size screenSize;
  final Offset dir; // 진행 단위벡터.
  final double flySpeed; // 0~1.
  final double dissipate; // done 후 흩어짐 0→1.
  final int seed;

  // 경로 따라 피어나는 뭉게구름 덩이 수(occlusion 뱅크 제거 — 가리지 않음).
  //  슬링샷은 위 하늘로 일관되게 솟으므로 경로(위쪽)에 구름을 촘촘히 깔아
  //  '구름 사이를 가르며' 지나가는 느낌을 강화(11→14).
  static const int _trailCount = 14;

  // 구름 톤(흰색~연한 라벤더). 어둡지 않게, 은은히.
  static const Color _cloudWhite = Color(0xFFFFFFFF);
  static const Color _cloudLavender = Color(0xFFEDE7FB);
  // 그림책 명암: 윗면 하이라이트(살짝 더 흰)·아랫면 옅은 라벤더 그늘.
  static const Color _cloudHighlight = Color(0xFFFFFFFF);
  static const Color _cloudShade = Color(0xFFD8CEF0);

  // 경로 위 한 점의 화면 좌표(비행기와 동일 공식).
  Offset _pathPoint(double t) =>
      center + _flightOffset(screenSize, dir, flySpeed, t);

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = Random(seed);
    // 진행 방향에 수직(lateral) 단위벡터 — 구름 측면 산포에 사용.
    final perp = Offset(-dir.dy, dir.dx);

    // ── 경로를 따라 점점이 피어나는 그림책 뭉게구름 ──
    // 경로 t∈[0.03, 0.86]에 결정적으로 분산 emit, 나이 들며 커지고 떠다니다 옅어짐.
    for (var i = 0; i < _trailCount; i++) {
      // 모든 파라미터를 먼저 결정적으로 소비(분기와 무관하게 RNG 스트림 고정 →
      // flyT 증가에 따른 구름 위치 점프 방지).
      final jitterT = rnd.nextDouble();
      final lateral = (rnd.nextDouble() - 0.5) * 110; // 경로 양옆 산포.
      final along = (rnd.nextDouble() - 0.5) * 44; // 경로 따라 미세 산포.
      final wobbleR = 0.85 + rnd.nextDouble() * 0.5; // 크기 변주.
      final tintPick = rnd.nextDouble();
      final lobeSeed = rnd.nextInt(1 << 30); // 이 덩이의 lobe 배치 시드(고정).

      // 결정적 emit 진행도(경로 전반에 고르게).
      final emitT = 0.03 + 0.83 * (i + jitterT * 0.6) / _trailCount;
      if (flyT < emitT) continue; // 아직 그 지점 미도달 — 그리지 않음.

      // 나이(0→1): emit 직후 0 → 비행 끝/그 이후로 갈수록 1.
      final age = ((flyT - emitT) / (1.0 - emitT)).clamp(0.0, 1.0);
      // 피어남: 작게 시작→천천히 커짐(easeOut).
      final grow = Curves.easeOut.transform(age);

      // 원근: 멀리(후반 emit) 피어난 구름일수록 작게(비행기 후퇴와 동조).
      final persp = 1.0 - emitT * 0.55; // emit 0→1 : 1.0→0.45 스케일.
      final radius = (30 + grow * 46) * wobbleR * persp;

      // 떠오름: 나이 들수록 살짝 위로 부유.
      final pos = _pathPoint(emitT) +
          perp * lateral * persp +
          dir * along +
          Offset(0, -grow * 24);

      // 불투명도: 등장(빠르게 0→peak) 후 서서히 옅어짐 + done 흩어짐.
      final appear = (age / 0.22).clamp(0.0, 1.0);
      final fade = (1.0 - (age - 0.45).clamp(0.0, 1.0) / 0.55);
      final opacity =
          (0.66 * appear * fade * (1.0 - dissipate)).clamp(0.0, 1.0);
      if (opacity <= 0.01) continue;

      // done 흩어짐: 살짝 더 위로 떠오르며 퍼짐.
      final driftPos = pos + Offset(0, -dissipate * 30);
      _cumulus(
        canvas,
        driftPos,
        radius * (1 + dissipate * 0.22),
        opacity,
        tintPick < 0.5 ? _cloudLavender : _cloudWhite,
        lobeSeed,
      );
    }
  }

  // ── 그림책 뭉게구름 한 덩이 ──
  // 아래는 평평, 위는 둥근 봉우리 여러 개. 여러 lobe(원호)를 겹쳐 실루엣을
  // 부드러운 흰색으로 채우고, 아랫면에 옅은 라벤더 그늘 + 윗면 하이라이트로
  // '그림책 구름'처럼 입체를 준다. 외곽은 약한 blur로 soft(형태는 유지).
  void _cumulus(Canvas canvas, Offset c, double r, double opacity, Color tint,
      int lobeSeed) {
    final rnd = Random(lobeSeed);
    // lobe(봉우리) 개수: 3~4개. 아래는 평평(밑변), 위로 봉우리들이 솟음.
    final lobeCount = 3 + (rnd.nextInt(2)); // 3 또는 4.
    final baseY = c.dy + r * 0.42; // 평평한 밑면 y(살짝 아래).

    // lobe 중심들: 가로로 펼쳐 배치, 가운데가 가장 높고 양끝이 낮은 봉우리.
    final lobes = <(Offset, double)>[]; // (center, radius)
    for (var i = 0; i < lobeCount; i++) {
      // -1..1 가로 위치(균등 + 약간의 지터).
      final u = lobeCount == 1
          ? 0.0
          : (i / (lobeCount - 1)) * 2 - 1 + (rnd.nextDouble() - 0.5) * 0.18;
      // 가운데 봉우리가 크고 높게, 양끝은 작고 낮게(뭉게구름 봉우리감).
      final centerness = 1 - u.abs(); // 0(끝)~1(가운데).
      final lobeR = r * (0.55 + centerness * 0.42 + rnd.nextDouble() * 0.08);
      final cx = c.dx + u * r * 0.92;
      // 봉우리 꼭대기가 밑면 위로 솟도록: 큰 lobe가 더 높이.
      final cy = baseY - lobeR * (0.78 + centerness * 0.30);
      lobes.add((Offset(cx, cy), lobeR));
    }

    // 실루엣 path: 각 lobe 원 + 밑변을 평평하게 자르는 사각형 결합(union).
    var silhouette = Path();
    for (final (lc, lr) in lobes) {
      silhouette = Path.combine(
        PathOperation.union,
        silhouette,
        Path()..addOval(Rect.fromCircle(center: lc, radius: lr)),
      );
    }
    // 밑면 아래를 잘라 평평한 바닥(cumulus 특징).
    final clip = Path()
      ..addRect(Rect.fromLTRB(
          c.dx - r * 2, c.dy - r * 2, c.dx + r * 2, baseY));
    final body = Path.combine(PathOperation.intersect, silhouette, clip);

    // soft 외곽: 약한 blur(형태가 구름으로 읽히도록 r에 비례해 작게).
    final blur = MaskFilter.blur(BlurStyle.normal, r * 0.12);

    // ① 아랫면 옅은 그늘(밑동을 라벤더로 깔아 입체) — 본체 아래쪽.
    canvas.save();
    canvas.clipPath(body);
    final shadeRect = Rect.fromLTRB(
        c.dx - r * 1.4, c.dy - r * 0.2, c.dx + r * 1.4, baseY + r * 0.2);
    canvas.drawRect(
      shadeRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            _cloudShade.withValues(alpha: 0.0),
            _cloudShade.withValues(alpha: opacity * 0.55),
          ],
        ).createShader(shadeRect),
    );
    canvas.restore();

    // ② 본체 채움: 부드러운 흰(틴트) — blur로 가장자리 soft.
    canvas.drawPath(
      body,
      Paint()
        ..maskFilter = blur
        ..color = tint.withValues(alpha: opacity),
    );

    // ③ 윗면 하이라이트: 각 봉우리 위쪽에 작은 흰 하이라이트(빛이 위에서).
    canvas.save();
    canvas.clipPath(body);
    for (final (lc, lr) in lobes) {
      final hc = lc + Offset(-lr * 0.18, -lr * 0.30);
      final hRect = Rect.fromCircle(center: hc, radius: lr * 0.7);
      canvas.drawCircle(
        hc,
        lr * 0.7,
        Paint()
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, lr * 0.22)
          ..shader = RadialGradient(
            colors: [
              _cloudHighlight.withValues(alpha: opacity * 0.5),
              _cloudHighlight.withValues(alpha: 0.0),
            ],
          ).createShader(hRect),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CloudFieldPainter old) =>
      old.flyT != flyT ||
      old.dissipate != dissipate ||
      old.center != center ||
      old.dir != dir ||
      old.flySpeed != flySpeed;
}

// ════════════════════════════════════════════════════════════════════════
// done 하늘 씬 페인터: '하늘 위를 두둥실 나는' 평온한 씬.
//   ① 하늘 그라데이션(상단 라벤더 하늘빛 → 하단 따뜻한 살구빛).
//   ② 한쪽 상단 은은한 햇무리(따뜻한 광원 글로우).
//   ③ 흘러가는 구름(3겹 패럴랙스): 먼 겹은 작고 느리고 옅게, 앞 겹은 크고 빠르고
//      또렷이 가로로 흘러 → '하늘을 가르며 떠가는' 깊이감. wrap-around로 끊김 없음.
//   ④ 두둥실 드리프트: 각 겹이 아주 느린 sin으로 상하 미세 부유(겹마다 다른
//      진폭/위상) → 무중력으로 떠 있는 느낌(비행기 rising/bob과 톤 일치).
//   - 결정적: Random(seed)로 구름 배치 고정(프레임 점프 0).
//   - drift(0→1, _skyDrift 왕복): 흐름 위상·부유 위상의 단일 시간 소스.
// ════════════════════════════════════════════════════════════════════════
class _SkyScenePainter extends CustomPainter {
  _SkyScenePainter({required this.drift, required this.seed});

  /// _skyDrift(0↔1 왕복). 흐름/부유 위상의 시간 기준.
  final double drift;
  final int seed;

  // 구름 톤(_CloudFieldPainter와 동일 톤 — 흰~연한 라벤더, 어둡지 않게).
  static const Color _cloudWhite = Color(0xFFFFFFFF);
  static const Color _cloudLavender = Color(0xFFF1ECFB);
  static const Color _cloudShade = Color(0xFFD8CEF0);

  // 패럴랙스 겹 정의: (구름 수, 속도배수, 크기배수, 불투명도, 세로위치비, 부유진폭).
  //  먼 겹(느리고 작고 옅음) → 앞 겹(빠르고 크고 또렷). 프레임 예산 내 총 11덩이.
  static const List<_SkyLayer> _layers = [
    _SkyLayer(count: 4, speed: 0.018, scale: 0.62, opacity: 0.42, bandY: 0.26, bobAmp: 5),
    _SkyLayer(count: 4, speed: 0.034, scale: 0.92, opacity: 0.62, bandY: 0.50, bobAmp: 8),
    _SkyLayer(count: 3, speed: 0.058, scale: 1.30, opacity: 0.80, bandY: 0.74, bobAmp: 12),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    // 하늘 그라데이션·햇무리 제거(사용자 요청) — 원래 다크 배경 위에 구름만 떠다닌다.

    // ── ③+④ 패럴랙스 구름 + 두둥실 부유 ──
    // drift(0↔1 왕복)를 부유 sin 위상으로, 누적 흐름은 별도 위상(painter 호출마다
    //  drift 값으로 결정적 — wrap-around라 경계 점프 없음).
    final bob = sin(drift * pi); // 0→1→0 (왕복이므로 부드러운 ±부유).
    final rnd = Random(seed);

    for (var li = 0; li < _layers.length; li++) {
      final layer = _layers[li];
      // 이 겹의 흐름 위상(0→1, wrap). drift를 속도배수로 환산 — 느린 겹은 천천히.
      //  drift가 0↔1 왕복이라 단조 증가가 아니므로, 가로 흐름은 위상을 |sin|이 아닌
      //  연속 좌우 스윙으로 둔다(부드럽게 좌↔우로 흘러가며 '가르는' 느낌).
      final flowPhase = sin(drift * pi * 2 * layer.speed * 16);
      for (var i = 0; i < layer.count; i++) {
        // 결정적 파라미터(분기 무관하게 RNG 스트림 고정).
        final baseX = rnd.nextDouble(); // 0~1 가로 기준 위치.
        final yJit = (rnd.nextDouble() - 0.5) * 0.10; // 밴드 내 세로 지터.
        final sizeJit = 0.82 + rnd.nextDouble() * 0.40;
        final phaseJit = rnd.nextDouble() * pi * 2; // 부유 위상 개체차.
        final tint = rnd.nextDouble() < 0.5 ? _cloudLavender : _cloudWhite;
        final lobeSeed = rnd.nextInt(1 << 30);

        // 가로 흐름: 기준 위치 + 겹 흐름 스윙. wrap-around로 화면 밖→반대편 등장.
        final span = w * 1.4; // 화면보다 넓게 깔아 양끝이 비지 않게.
        var x = (baseX * span + flowPhase * w * 0.5) % span - w * 0.2;
        // 세로: 겹 밴드 + 지터 + 개체별 두둥실 부유(sin, 느린 공통 bob).
        final y = h * (layer.bandY + yJit) +
            sin(phaseJit + drift * pi) * layer.bobAmp +
            bob * layer.bobAmp * 0.4;

        final r = 40 * layer.scale * sizeJit;
        _drawCloud(canvas, Offset(x, y), r, layer.opacity, tint, lobeSeed);
      }
    }
  }

  // ── 뭉게구름 한 덩이(평평한 밑면 + 둥근 봉우리들, soft blur) ──
  //   _CloudFieldPainter._cumulus와 동일 실루엣 기법(아래 평평/위 봉우리 union +
  //   아랫면 라벤더 그늘 + 본체 흰 채움 + 윗면 하이라이트). done 씬용 경량 변형.
  void _drawCloud(Canvas canvas, Offset c, double r, double opacity, Color tint,
      int lobeSeed) {
    final rnd = Random(lobeSeed);
    final lobeCount = 3 + rnd.nextInt(2); // 3 또는 4 봉우리.
    final baseY = c.dy + r * 0.42;

    final lobes = <(Offset, double)>[];
    for (var i = 0; i < lobeCount; i++) {
      final u = lobeCount == 1
          ? 0.0
          : (i / (lobeCount - 1)) * 2 - 1 + (rnd.nextDouble() - 0.5) * 0.18;
      final centerness = 1 - u.abs();
      final lobeR = r * (0.55 + centerness * 0.42 + rnd.nextDouble() * 0.08);
      final cx = c.dx + u * r * 0.92;
      final cy = baseY - lobeR * (0.78 + centerness * 0.30);
      lobes.add((Offset(cx, cy), lobeR));
    }

    var silhouette = Path();
    for (final (lc, lr) in lobes) {
      silhouette = Path.combine(
        PathOperation.union,
        silhouette,
        Path()..addOval(Rect.fromCircle(center: lc, radius: lr)),
      );
    }
    final clip = Path()
      ..addRect(Rect.fromLTRB(c.dx - r * 2, c.dy - r * 2, c.dx + r * 2, baseY));
    final body = Path.combine(PathOperation.intersect, silhouette, clip);

    final blur = MaskFilter.blur(BlurStyle.normal, r * 0.14);

    // 아랫면 옅은 라벤더 그늘.
    canvas.save();
    canvas.clipPath(body);
    final shadeRect =
        Rect.fromLTRB(c.dx - r * 1.4, c.dy - r * 0.2, c.dx + r * 1.4, baseY + r * 0.2);
    canvas.drawRect(
      shadeRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            _cloudShade.withValues(alpha: 0.0),
            _cloudShade.withValues(alpha: opacity * 0.45),
          ],
        ).createShader(shadeRect),
    );
    canvas.restore();

    // 본체 흰(틴트) 채움 + soft 외곽.
    canvas.drawPath(
      body,
      Paint()
        ..maskFilter = blur
        ..color = tint.withValues(alpha: opacity),
    );

    // 윗면 하이라이트(빛이 위에서).
    canvas.save();
    canvas.clipPath(body);
    for (final (lc, lr) in lobes) {
      final hc = lc + Offset(-lr * 0.18, -lr * 0.30);
      final hRect = Rect.fromCircle(center: hc, radius: lr * 0.7);
      canvas.drawCircle(
        hc,
        lr * 0.7,
        Paint()
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, lr * 0.22)
          ..shader = RadialGradient(
            colors: [
              _cloudWhite.withValues(alpha: opacity * 0.5),
              _cloudWhite.withValues(alpha: 0.0),
            ],
          ).createShader(hRect),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _SkyScenePainter old) =>
      old.drift != drift || old.seed != seed;
}

/// done 하늘 씬 패럴랙스 한 겹 정의(원근 깊이별 속도/크기/불투명도/부유).
class _SkyLayer {
  const _SkyLayer({
    required this.count,
    required this.speed,
    required this.scale,
    required this.opacity,
    required this.bandY,
    required this.bobAmp,
  });

  final int count; // 이 겹 구름 수.
  final double speed; // 가로 흐름 속도배수(작을수록 먼 겹).
  final double scale; // 크기배수.
  final double opacity; // 기본 불투명도.
  final double bandY; // 세로 배치 비율(0=상단, 1=하단).
  final double bobAmp; // 두둥실 상하 부유 진폭(px).
}
