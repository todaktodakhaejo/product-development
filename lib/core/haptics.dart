import 'dart:async';

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
