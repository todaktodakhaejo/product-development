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
  /// (구버전 — v2부터 [strokeSoft]로 대체. 타 곳 미사용 시 정리 대상.)
  void rubTick() => fire(HapticLevel.light);

  // ── 제스처 v2 신규 햅틱 (§12.1 인터페이스 계약) ──────────────────────
  // 연속 패턴(strokeSoft/rollFriction)은 home_screen이 매 프레임/이동마다
  // 불러도 폭주하지 않도록 각자 독립 타임스탬프로 throttle한다.
  // (전역 _allow()는 fire()와 공유되므로 여기서 재사용하지 않는다 — 서로
  //  엉켜서 한쪽이 다른 쪽을 잡아먹는 걸 막기 위해 메서드별 게이트를 둔다.)
  // 단발 패턴(pressDown/pressRelease)은 침몰·복원의 결정적 순간이라 throttle 무시.
  //
  // 모두 내부적으로 HapticFeedback만 호출 → 햅틱 미지원 기기에선 자동 noop(예외 없음).
  // iOS Core Haptics의 연속·가변 강도(부드럽게 흐르는 텍스처, speed 비례 amplitude)는
  // 네이티브 채널이 있어야 진짜로 살아난다 → 실기기/네이티브 작업 필요(이번 범위 밖).

  DateTime _strokeLast = DateTime.fromMillisecondsSinceEpoch(0);
  final Duration _strokeGap = const Duration(milliseconds: 40);

  /// 쓰다듬기(GST-04) 연속 약진동. 위로받는 잔잔한 텍스처.
  /// [rubTick]의 딱딱한 light 반복보다 부드럽게, ~40ms 간격으로 흐르듯 발사.
  /// home_screen이 stroke 모드 매 move마다 호출 → 내부 throttle로 폭주 차단.
  void strokeSoft() {
    final now = DateTime.now();
    if (now.difference(_strokeLast) < _strokeGap) return;
    _strokeLast = now;
    // selectionClick: lightImpact보다 가볍고 결이 고와 "쓸리는" 느낌에 가깝다.
    // (Core Haptics 연속 진동이 이상적 — 실기기/네이티브 작업 필요.)
    HapticFeedback.selectionClick();
  }

  DateTime _rollLast = DateTime.fromMillisecondsSinceEpoch(0);
  final Duration _rollGap = const Duration(milliseconds: 28);

  /// 굴리기(GST-02) 마찰 틱. 구슬이 바닥을 구르는 자글한 텍스처감.
  /// [speed01](0~1, 추종속도/2600)에 따라 light~medium 가변.
  /// home_screen이 이동 누적 거리마다 호출 → 내부 ~28ms throttle.
  void rollFriction(double speed01) {
    final now = DateTime.now();
    if (now.difference(_rollLast) < _rollGap) return;
    _rollLast = now;
    final s = speed01.clamp(0.0, 1.0);
    // 빠를수록 굵은 자글거림. 느릴 땐 가볍게 톡톡.
    HapticFeedback.lightImpact();
    if (s >= 0.6) HapticFeedback.mediumImpact();
  }

  /// 누르기(GST-03) 침몰 순간. 쑥 들어가는 묵직함 — medium 1회.
  /// 탭의 결정적 순간이므로 throttle 무시(§12.1).
  void pressDown() => HapticFeedback.mediumImpact();

  /// 누르기(GST-03) 복원 정점. 차오르며 톡 올라오는 느낌 — light 1회.
  /// 복원 정점 프레임의 단발이므로 throttle 무시(§12.1).
  void pressRelease() => HapticFeedback.lightImpact();

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
