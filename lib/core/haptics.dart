import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/animation.dart';
import 'package:flutter/services.dart';

/// 햅틱 세기 단계. Flutter 내장 HapticFeedback은 고정 단계만 제공하므로
/// 충격 세기(impact strength)를 이 단계로 매핑해서 사용한다.
enum HapticLevel { selection, light, medium, heavy, success }

/// 앱 전역 햅틱 엔진.
///
/// - 제스처 인터랙션에서는 [impactBySpeed]로 충돌 세기에 맞춰 진동.
/// - 의식(분출) 연출에서는 [playTimeline]으로 애니메이션 진행도(0~1)의
///   키프레임마다 햅틱 큐를 발사 → 모션과 진동이 한 축에서 움직인다.
class Haptics {
  Haptics._();
  static final Haptics instance = Haptics._();

  final Duration _minGap = const Duration(milliseconds: 28);
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  /// 너무 잦은 진동 방지용 throttle. 직전 발사 후 [_minGap] 이내면 무시.
  bool _allow() {
    final now = DateTime.now();
    if (now.difference(_last) < _minGap) return false;
    _last = now;
    return true;
  }

  void fire(HapticLevel level, {bool throttle = true}) {
    if (throttle && !_allow()) return;
    switch (level) {
      case HapticLevel.selection:
        HapticFeedback.selectionClick();
      case HapticLevel.light:
        HapticFeedback.lightImpact();
      case HapticLevel.medium:
        HapticFeedback.mediumImpact();
      case HapticLevel.heavy:
        HapticFeedback.heavyImpact();
      case HapticLevel.success:
        // 완료감: heavy 한 번. (iOS Core Haptics 연동 시 success 패턴으로 교체)
        HapticFeedback.heavyImpact();
    }
  }

  /// 0~1로 정규화된 강도를 단계로 매핑해 발사. (예: 벽 충돌 속도)
  void impactByStrength(double t, {bool throttle = true}) {
    final c = t.clamp(0.0, 1.0);
    if (c < 0.12) return; // 미세한 접촉은 무시
    final level = c < 0.35
        ? HapticLevel.light
        : c < 0.7
            ? HapticLevel.medium
            : HapticLevel.heavy;
    fire(level, throttle: throttle);
  }

  /// 속도(px/s 등 임의 단위)를 [maxSpeed] 기준으로 정규화해 발사.
  void impactBySpeed(double speed, {double maxSpeed = 2600}) {
    impactByStrength((speed / maxSpeed));
  }

  /// 잡고 문지르기(GST-04)용 지속적 약한 진동 틱.
  void rubTick() => fire(HapticLevel.light);

  // ── P3 신규: 부드러운 성공 / 연속 진동 근사 ──────────────────────
  // 의식 고도화(태우기 잔불 마무리·보석함 닫힘·파쇄기 투입)용.
  // 모두 graceful degradation: 미지원/웹에서 HapticFeedback은 무음 통과.

  /// 부드러운 성공 마무리. heavy 단발 대신 medium→(지연)→light 2펄스 디케이로
  /// '포근하게 잦아드는' 마무리감을 만든다. 보석함 뚜껑 닫힘·태우기 잔불용.
  ///
  /// 시퀀스이므로 [Future]로 await 가능(타이밍 동기화 필요 시).
  /// throttle을 우회해 두 펄스가 모두 발사되도록 한다.
  Future<void> softSuccess() async {
    // 첫 펄스: 살짝 묵직하게 안착감.
    fire(HapticLevel.medium, throttle: false);
    // 디케이 간격 후 약하게 한 번 더 — 여운처럼.
    await Future<void>.delayed(const Duration(milliseconds: 90));
    fire(HapticLevel.light, throttle: false);
  }

  /// 연속 진동 근사(파쇄기 '갈리는' 질감용).
  ///
  /// 내장 [HapticFeedback]엔 연속 진동이 없으므로 짧은 임팩트를 일정 간격으로
  /// 반복해 흉내낸다. [fire]의 28ms 글로벌 throttle을 우회하려고 자체 타이머로
  /// `throttle:false` 발사한다.
  ///
  /// [intensity](0~1)가 높을수록 더 강한 레벨·더 촘촘한 간격으로 울린다.
  /// [total]은 안전장치(자동 종료 시한)일 뿐 — **드래그 동안만 울리려면 반환된
  /// [RumbleHandle.stop]을 onDragEnd/dispose에서 반드시 호출**한다(무한진동·누수 방지).
  ///
  /// 사용 예:
  /// ```dart
  /// final rumble = Haptics.instance.rumble();      // onDragStart
  /// rumble.setIntensity(dragSpeedNormalized);       // onDragUpdate (선택)
  /// rumble.stop();                                  // onDragEnd / dispose
  /// ```
  RumbleHandle rumble({
    Duration total = const Duration(seconds: 8),
    double intensity = 0.5,
  }) {
    final handle = RumbleHandle._(this, intensity);
    handle._start(total);
    return handle;
  }

  /// [RumbleHandle]이 내부적으로 1펄스 발사할 때 사용(throttle 우회).
  void _rumblePulse(double intensity) {
    // 강도에 따라 레벨 양자화: 낮으면 light, 높으면 medium.
    final level = intensity >= 0.5 ? HapticLevel.medium : HapticLevel.light;
    fire(level, throttle: false);
  }

  // ── 파쇄기(shredder) 전용 햅틱 ──────────────────────────────────────
  // 명세 §5.3/§5.4. rumble과 형제이지만 grinding 고유의 '고조 곡선·말미
  // 촘촘함·모터 지터'를 내장한 별도 드라이버다(기존 rumble은 그대로 유지).
  //
  // ⚠️ 연속 진동은 OS 네이티브 미배선 → 짧은 임팩트를 타이머로 반복하는
  // **근사**가 전부다. 실제 '도는 모터' 질감 튜닝은 실기기에서만 검증 가능.
  // 미지원/웹에서는 [fire]가 HapticFeedback 무음 통과 → 예외 없이 무동작.

  /// 파쇄기 연속 그라인드(§5.3). 시작 즉시 모터 질감 연속 펄스가 돌기 시작한다.
  ///
  /// 3초 동안 ~45ms 간격(말미 35ms)으로 임팩트를 반복해 '그르렁대는 모터'를
  /// 흉내낸다. 강도는 자체 경과시간 기반 기본 곡선(medium→heavy 고조)으로도 동작하며,
  /// [GrindHandle.setProgress]로 화면 진행도(0~1)를 주입하면 그 곡선을 따른다.
  ///
  /// 반환된 [GrindHandle.stop]을 **bursting 진입·dispose에서 반드시 호출**한다
  /// (무한 진동·타이머 누수 방지). 안전장치로 4초 후 자동 stop된다.
  GrindHandle startShredGrind() {
    final handle = GrindHandle._(this);
    handle._start();
    return handle;
  }

  /// [GrindHandle]이 1펄스 발사할 때 사용(throttle 우회).
  ///
  /// grind 강도(0~1)를 레벨로 양자화한다. 실기기 피드백(2026-06-01: 분쇄 진동이
  /// 너무 약함)으로 한 단계 끌어올렸다 — grinding엔 **light를 쓰지 않고** medium을
  /// 바닥, 중반 이후(≥0.62)와 최말미 고조 구간은 heavy를 상시 사용해 묵직하게 한다.
  /// (HapticFeedback의 천장은 heavyImpact. 더 센 '연속' 진동은 Core Haptics 필요.)
  void _grindPulse(double intensity, {bool spikeHeavy = false}) {
    final level = (intensity >= 0.62 || spikeHeavy)
        ? HapticLevel.heavy
        : HapticLevel.medium;
    fire(level, throttle: false);
  }

  // ── 태우기(burn) 전용 햅틱 ──────────────────────────────────────────
  // 명세 §4(햅틱). 파쇄기 [startShredGrind]의 **형제** 드라이버다 — 같은
  // '타이머로 짧은 임팩트를 반복하는 연속 진동 근사' 구조에, 태우기 고유의
  // '아래→위 화력 고조 곡선(0.55→1.0)·말미 촘촘함(35ms)·불 일렁임 지터'를
  // 내장한다(기존 [rumble]/[startShredGrind]는 그대로 유지).
  //
  // ⚠️ 연속 진동은 OS 네이티브 미배선 → 짧은 임팩트를 타이머로 반복하는
  // **근사**가 전부다. 실제 '타오르는 불' 질감(점점 강해지는 연속 진동)
  // 튜닝은 실기기에서만 검증 가능. 미지원/웹에서는 [fire]가 HapticFeedback
  // 무음 통과 → 예외 없이 무동작(§9 폴백).

  /// 태우기 연속 연소(§4 햅틱). 점화 시 시작, 불이 커질수록 강해지는 연속 진동.
  ///
  /// 3초 동안 ~45ms 간격(말미 35ms)으로 임팩트를 반복해 '아래→위로 활활 번지는
  /// 불길'을 흉내낸다. 강도는 자체 경과시간 기반 기본 곡선(medium→heavy 고조)으로도
  /// 동작하며, [BlazeHandle.setProgress]로 화면 `_burnCtrl.value`(0~1)를 매 프레임
  /// 주입하면 그 화력 곡선을 따른다.
  ///
  /// 반환된 [BlazeHandle.stop]을 **전소(softSuccess 직전)·dispose에서 반드시 호출**
  /// 한다(무한 진동·타이머 누수 방지). 안전장치로 4초 후 자동 stop된다.
  /// ⚠️ 마무리는 호출측이 [BlazeHandle.stop]을 [softSuccess]보다 **먼저** 부른다
  /// (겹침 방지) — 이 드라이버는 [softSuccess]를 직접 호출하지 않는다.
  BlazeHandle startBurnBlaze() {
    final handle = BlazeHandle._(this);
    handle._start();
    return handle;
  }

  /// [BlazeHandle]이 1펄스 발사할 때 사용(throttle 우회).
  ///
  /// blaze 강도(0~1)를 레벨로 양자화한다. 사용자 피드백(2026-06-02: 불이
  /// 아래에서 위로 **약→강 점진**)으로 3밴드로 — 점화 직후(아래)는 **light(약)**,
  /// 중반은 **medium**, 위(≥0.70)·최말미 정점은 **heavy(강)**. 전소로 갈수록 강해진다.
  /// (HapticFeedback의 천장은 heavyImpact. 더 센 '연속' 진동은 Core Haptics 필요.)
  void _blazePulse(double intensity, {bool spikeHeavy = false}) {
    final HapticLevel level;
    if (intensity >= 0.70 || spikeHeavy) {
      level = HapticLevel.heavy;
    } else if (intensity >= 0.42) {
      level = HapticLevel.medium;
    } else {
      level = HapticLevel.light;
    }
    fire(level, throttle: false);
  }

  /// 폭죽 연쇄 팝(§5.4). 호출 즉시 내부 지연 타이머로 전체 시퀀스를 발사한다.
  ///
  /// 강한 1발(heavy+success 겹침) 후 흩어지는 다수 팝(medium/light)이 ~380ms에
  /// 걸쳐 잦아든다. 모두 `throttle:false`. 화면은 bursting 진입 순간 1회만 호출하고,
  /// 시각 폭죽과 같은 프레임에 호출하면 동기된다.
  ///
  /// 외부 상태를 참조하지 않으므로 화면이 도중에 dispose돼도 무해하다
  /// (엔진 싱글톤·짧은 시퀀스). 미지원/웹에서는 무음 통과.
  void burstPop() {
    // ms 시퀀스(bursting 진입=0 기준): §5.4 그대로.
    // 0ms: heavy + success(겹침) → 묵직한 임팩트 두께.
    fire(HapticLevel.heavy, throttle: false);
    fire(HapticLevel.success, throttle: false);
    // 흩어지는 팝들. 각 지연마다 1발씩(외부 상태 참조 없음).
    Future<void>.delayed(const Duration(milliseconds: 70),
        () => fire(HapticLevel.medium, throttle: false)); // 첫 흩어짐
    Future<void>.delayed(const Duration(milliseconds: 130),
        () => fire(HapticLevel.light, throttle: false));
    Future<void>.delayed(const Duration(milliseconds: 190),
        () => fire(HapticLevel.light, throttle: false));
    Future<void>.delayed(const Duration(milliseconds: 220),
        () => fire(HapticLevel.medium, throttle: false)); // sparkle 2차 동기
    Future<void>.delayed(const Duration(milliseconds: 300),
        () => fire(HapticLevel.light, throttle: false));
    Future<void>.delayed(const Duration(milliseconds: 380),
        () => fire(HapticLevel.light, throttle: false)); // 마지막 잔향
  }

  // ── P3 신규: 의식별 타임라인/스텝 큐 빌더 ────────────────────────
  // playTimeline(controller, cues)에 그대로 넣을 수 있는 List<HapticCue> 생성.

  /// 태우기(burn) 진행 타임라인 큐.
  ///
  /// 진행도 0→1을 따라 **비감소(앞 큐 ≤ 뒤 큐)** 로 강해진다 — 불이 번지며
  /// 가속하는 느낌. 시작은 가장 약하고(light) 끝은 가장 강하다(heavy).
  /// 큐 5개. `playTimeline`이 각 지점에서 1회씩 발사한다.
  ///
  /// 완료(전소) 직후의 '잦아드는 잔불' 마무리는 이 타임라인이 아니라
  /// 화면의 onComplete에서 [softSuccess]를 호출해 표현한다(아래 notes 참조).
  static List<HapticCue> burnTimeline() => const [
        HapticCue(0.0, HapticLevel.light), // 불씨가 옮겨붙음
        HapticCue(0.25, HapticLevel.light), // 가장자리부터 천천히
        HapticCue(0.5, HapticLevel.medium), // 번지기 시작
        HapticCue(0.75, HapticLevel.medium), // 활활
        HapticCue(1.0, HapticLevel.heavy), // 전소 직전 최고조
      ];

  /// 종이비행기 접기 단계 큐(현행 동작 호환): light·light·medium 3큐.
  /// 마지막 접힘이 가장 단단한 느낌(medium)이 되도록 비감소 구성.
  static List<HapticCue> foldStepCue() => const [
        HapticCue(0.2, HapticLevel.light), // 첫 접힘
        HapticCue(0.5, HapticLevel.light), // 두 번째 접힘
        HapticCue(0.85, HapticLevel.medium), // 마지막 단단히 눌러 접기
      ];

  // ── 타임라인 햅틱 ────────────────────────────────────────────────
  // 애니메이션 컨트롤러(0~1)에 cue 목록을 붙여 진행도가 지점을 넘을 때 발사.

  /// [controller] 한 번 실행 동안 [cues]의 각 (at, level)을 1회씩 발사.
  /// 반환된 함수를 dispose 시 호출하면 리스너가 제거된다.
  VoidCallback playTimeline(
    AnimationController controller,
    List<HapticCue> cues,
  ) {
    final fired = <int>{};
    void listener() {
      final t = controller.value;
      for (var i = 0; i < cues.length; i++) {
        if (t >= cues[i].at && fired.add(i)) {
          fire(cues[i].level, throttle: false);
        }
      }
    }

    controller.addListener(listener);
    return () => controller.removeListener(listener);
  }
}

/// 타임라인 햅틱 큐: 진행도 [at](0~1)에서 [level] 발사.
class HapticCue {
  const HapticCue(this.at, this.level);
  final double at;
  final HapticLevel level;
}

/// [Haptics.rumble]이 반환하는 연속 진동 제어 핸들.
///
/// 시작 시점에 타이머가 돌기 시작하고, [stop]을 호출하면 즉시 멈춘다.
/// **드래그 종료·화면 dispose에서 반드시 [stop]을 호출**해야 무한 진동·
/// 타이머 누수를 막을 수 있다. [stop]은 중복 호출해도 안전하다(idempotent).
class RumbleHandle {
  RumbleHandle._(this._engine, double intensity)
      : _intensity = intensity.clamp(0.0, 1.0);

  final Haptics _engine;
  double _intensity;
  Timer? _timer;
  bool _stopped = false;

  /// 강도(0~1)에 따라 펄스 간격을 매핑: 강할수록 촘촘하게(30~60ms).
  Duration get _interval {
    final ms = (60 - _intensity * 30).round().clamp(30, 60);
    return Duration(milliseconds: ms);
  }

  void _start(Duration total) {
    if (_stopped) return;
    _engine._rumblePulse(_intensity); // 즉시 첫 펄스(반응 지연 최소화)
    _timer = Timer.periodic(_interval, (_) {
      _engine._rumblePulse(_intensity);
    });
    // 안전장치: total 경과 시 자동 종료(stop 누락 대비).
    Future<void>.delayed(total, stop);
  }

  /// 실시간 강도 갱신(예: 드래그 속도 → 진동 세기). 간격도 재적용한다.
  void setIntensity(double v) {
    if (_stopped) return;
    _intensity = v.clamp(0.0, 1.0);
    _timer?.cancel();
    _timer = Timer.periodic(_interval, (_) {
      _engine._rumblePulse(_intensity);
    });
  }

  /// 연속 진동 중지(+타이머 해제). 중복 호출 안전.
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }

  /// [stop]의 별칭 — dispose 흐름에서 의도가 드러나도록.
  void dispose() => stop();
}

/// [Haptics.startShredGrind]가 반환하는 파쇄기 연속 그라인드 제어 핸들(§5.3).
///
/// [RumbleHandle]의 형제격이지만, grinding 고유의 '강도 고조 곡선(0.60→1.0)·
/// 말미 촘촘함(35ms)·모터 지터'를 내장한다. 시작 시점에 ~45ms 타이머가 돌며,
/// [stop]을 호출하면 즉시 멈춘다.
///
/// **bursting 진입·화면 dispose에서 반드시 [stop]을 호출**해야 무한 진동·타이머
/// 누수를 막는다. [stop]은 중복 호출해도 안전하다(idempotent). 안전장치로 시작
/// 후 [_safety] 경과 시 자동 [stop]된다(호출측 stop 누락 대비).
class GrindHandle {
  GrindHandle._(this._engine);

  final Haptics _engine;

  /// 그라인드 명목 길이(§4.2 GRIND_DURATION과 동일한 3초).
  static const Duration _duration = Duration(milliseconds: 3000);

  /// stop 누락 대비 자동 종료 시한(명목 3초 + 여유).
  static const Duration _safety = Duration(milliseconds: 4000);

  Timer? _timer;
  bool _stopped = false;

  /// 시작 시각 — setProgress 미호출 시 자체 경과시간으로 기본 곡선을 만든다.
  final Stopwatch _watch = Stopwatch();

  /// 외부 주입 진행도(0~1). null이면 [_watch] 경과 기반 기본 곡선을 쓴다.
  double? _externalT;

  void _start() {
    if (_stopped) return;
    _watch.start();
    _engine._grindPulse(_curveIntensity()); // 즉시 첫 펄스(반응 지연 최소화)
    _schedule();
    // 안전장치: 시한 경과 시 자동 종료.
    Future<void>.delayed(_safety, stop);
  }

  /// 현재 진행도(0~1) — 주입값 우선, 없으면 경과시간 기반.
  double _progress() {
    final ext = _externalT;
    if (ext != null) return ext.clamp(0.0, 1.0);
    return (_watch.elapsedMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
  }

  /// 진행도 t(0~1) → 강도. §5.3 키프레임을 선형 보간한 0.60→1.0 상승 곡선에
  /// '도는 모터'용 미세 sin 변조(±0.06)를 얹는다.
  double _curveIntensity() {
    final t = _progress();
    // 키프레임(실기기 강화 2026-06-01): 0.0→0.60, 0.33→0.72, 0.66→0.85,
    // 0.80→0.93, 1.0→1.00. medium에서 출발해 빠르게 heavy로 올라 폭죽 직전 최고조.
    final double base;
    if (t < 0.33) {
      base = _lerp(0.60, 0.72, t / 0.33);
    } else if (t < 0.66) {
      base = _lerp(0.72, 0.85, (t - 0.33) / 0.33);
    } else if (t < 0.80) {
      base = _lerp(0.85, 0.93, (t - 0.66) / 0.14);
    } else {
      base = _lerp(0.93, 1.00, (t - 0.80) / 0.20);
    }
    // 모터 회전감: 약 3Hz로 강도를 흔든다(t를 위상으로 사용).
    final wobble = 0.06 * math.sin(t * 2 * math.pi * 3);
    return (base + wobble).clamp(0.0, 1.0);
  }

  /// 진행도에 따른 펄스 간격. 기본 ~45ms, 말미(t≥0.9)는 35ms로 촘촘.
  /// '도는 모터'감을 위해 ±8ms 지터를 얹는다.
  Duration _nextInterval() {
    final t = _progress();
    final baseMs = t >= 0.9 ? 35 : 45;
    // 경과 ms 기반 의사난수 지터(±8ms) — 외부 의존 없이 결정적·가벼움.
    final jitter = (_watch.elapsedMicroseconds % 17) - 8; // -8..+8
    final ms = (baseMs + jitter).clamp(28, 60);
    return Duration(milliseconds: ms);
  }

  /// 매 펄스마다 간격을 재계산해 1발 발사하고 다음 펄스를 예약(가변 간격).
  void _schedule() {
    if (_stopped) return;
    _timer = Timer(_nextInterval(), () {
      if (_stopped) return;
      final t = _progress();
      // 최말미(≥0.9) 순간엔 heavy를 가끔 섞어 폭죽 직전 텐션.
      _engine._grindPulse(_curveIntensity(), spikeHeavy: t >= 0.9);
      _schedule();
    });
  }

  /// 매 프레임 진행도(0~1) 주입 — 강도 고조·말미 촘촘함을 화면 컨트롤러에 동조.
  /// 선택 사항(미호출 시 자체 경과시간 기반 기본 곡선으로 동작).
  void setProgress(double t) {
    if (_stopped) return;
    _externalT = t.clamp(0.0, 1.0);
    // 강도/간격은 다음 펄스 예약 시점에 자동 반영되므로 타이머 재설정 불필요.
  }

  /// 연속 그라인드 중지(+타이머 해제). 중복 호출 안전.
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    _watch.stop();
  }

  static double _lerp(double a, double b, double t) =>
      a + (b - a) * t.clamp(0.0, 1.0);
}

/// [Haptics.startBurnBlaze]가 반환하는 태우기 연속 연소 제어 핸들(§4 햅틱).
///
/// [GrindHandle]의 **형제**격이지만, 태우기 고유의 '아래→위 화력 고조 곡선
/// (0.55→1.0)·말미 촘촘함(35ms)·불 일렁임 지터'를 내장한다. 시작 시점에 ~45ms
/// 타이머가 돌며, [stop]을 호출하면 즉시 멈춘다.
///
/// **전소(softSuccess 직전)·화면 dispose에서 반드시 [stop]을 호출**해야 무한
/// 진동·타이머 누수를 막는다. [stop]은 중복 호출해도 안전하다(idempotent).
/// 안전장치로 시작 후 [_safety] 경과 시 자동 [stop]된다(호출측 stop 누락 대비).
///
/// ⚠️ 연속 진동은 OS 네이티브 미배선 → 짧은 임팩트의 타이머 반복 **근사**가
/// 전부다. '점점 강해지는 연속 진동' 손맛 튜닝은 실기기에서만 검증 가능.
class BlazeHandle {
  BlazeHandle._(this._engine);

  final Haptics _engine;

  /// 연소 명목 길이(화면 `_kBurnDuration`과 동일한 3초).
  static const Duration _duration = Duration(milliseconds: 3000);

  /// stop 누락 대비 자동 종료 시한(명목 3초 + 여유).
  static const Duration _safety = Duration(milliseconds: 4000);

  Timer? _timer;
  bool _stopped = false;

  /// 시작 시각 — setProgress 미호출 시 자체 경과시간으로 기본 곡선을 만든다.
  final Stopwatch _watch = Stopwatch();

  /// 외부 주입 진행도(0~1). null이면 [_watch] 경과 기반 기본 곡선을 쓴다.
  double? _externalT;

  void _start() {
    if (_stopped) return;
    _watch.start();
    _engine._blazePulse(_curveIntensity()); // 즉시 첫 펄스(점화 반응 지연 최소화)
    _schedule();
    // 안전장치: 시한 경과 시 자동 종료.
    Future<void>.delayed(_safety, stop);
  }

  /// 현재 진행도(0~1) — 주입값 우선, 없으면 경과시간 기반.
  double _progress() {
    final ext = _externalT;
    if (ext != null) return ext.clamp(0.0, 1.0);
    return (_watch.elapsedMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
  }

  /// 진행도 t(0~1) → 강도. §4(햅틱) 키프레임을 선형 보간한 0.55→1.0 상승 곡선에
  /// '타오르는 불 일렁임'용 미세 sin 변조(±0.06)를 얹는다.
  ///
  /// 파쇄기 [GrindHandle._curveIntensity](0.60→1.0)보다 점화 직후가 살짝 낮게(0.55)
  /// 출발하지만 medium 대역(≥0.62 미만)이라 톤은 일치 — '활활 고조'라 후반 가속이
  /// 좀 더 가파르다(t=0.4→0.72, 0.7→0.88, 1.0→1.00).
  double _curveIntensity() {
    final t = _progress();
    // 약→강 점진(사용자 피드백 2026-06-02): 아래(점화 직후)는 약하게(light),
    // 위로 갈수록 강하게(heavy). 키프레임 0.0→0.28, 0.4→0.55, 0.7→0.80, 1.0→1.00.
    final double base;
    if (t < 0.4) {
      base = _lerp(0.28, 0.55, t / 0.4);
    } else if (t < 0.7) {
      base = _lerp(0.55, 0.80, (t - 0.4) / 0.3);
    } else {
      base = _lerp(0.80, 1.00, (t - 0.7) / 0.3);
    }
    // 불 일렁임: 약 4.5Hz로 강도를 흔든다(t를 위상으로 사용 — '타오르는 떨림').
    // 진폭을 줄여(±0.05) 초반 약한 대역이 흔들려 사라지지 않게 한다.
    final wobble = 0.05 * math.sin(t * 2 * math.pi * 4.5);
    return (base + wobble).clamp(0.0, 1.0);
  }

  /// 진행도에 따른 펄스 간격. 기본 ~45ms, 말미(t≥0.9)는 35ms로 촘촘(전소 직전 텐션).
  /// '불 일렁임'을 위해 ±8ms 지터를 얹는다.
  Duration _nextInterval() {
    final t = _progress();
    final baseMs = t >= 0.9 ? 35 : 45;
    // 경과 ms 기반 의사난수 지터(±8ms) — 외부 의존 없이 결정적·가벼움.
    final jitter = (_watch.elapsedMicroseconds % 17) - 8; // -8..+8
    final ms = (baseMs + jitter).clamp(28, 60);
    return Duration(milliseconds: ms);
  }

  /// 매 펄스마다 간격을 재계산해 1발 발사하고 다음 펄스를 예약(가변 간격).
  void _schedule() {
    if (_stopped) return;
    _timer = Timer(_nextInterval(), () {
      if (_stopped) return;
      final t = _progress();
      // 최말미(≥0.9) 순간엔 heavy를 상시 섞어 전소 직전 정점 텐션.
      _engine._blazePulse(_curveIntensity(), spikeHeavy: t >= 0.9);
      _schedule();
    });
  }

  /// 매 프레임 진행도(0~1) 주입 — 화력 고조·말미 촘촘함을 화면 `_burnCtrl`에 동조.
  /// 선택 사항(미호출 시 자체 경과시간 기반 기본 곡선으로 동작).
  void setProgress(double t) {
    if (_stopped) return;
    _externalT = t.clamp(0.0, 1.0);
    // 강도/간격은 다음 펄스 예약 시점에 자동 반영되므로 타이머 재설정 불필요.
  }

  /// 연속 연소 중지(+타이머 해제). 중복 호출 안전.
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    _watch.stop();
  }

  /// [stop]의 별칭 — dispose 흐름에서 의도가 드러나도록(계약 §4).
  void dispose() => stop();

  static double _lerp(double a, double b, double t) =>
      a + (b - a) * t.clamp(0.0, 1.0);
}
