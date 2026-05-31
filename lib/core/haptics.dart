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
