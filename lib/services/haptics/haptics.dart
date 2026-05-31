/// 햅틱 패턴 카탈로그 (docs/PRODUCT_SPEC.md 5.1).
///
/// 화면/모션 코드는 이 패턴명만 호출하고, [Haptics] 구현체가 플랫폼을 분기한다.
enum HapticPattern {
  tapPop, // 통
  pressHum, // 누름 지속 (연속)
  rubTexture, // 사락/뽀드득 (속도 비례 연속)
  shakeBounce, // 벽 튕김 (강도 비례)
  heartbeat, // 두-근 (주기 반복)
  shredGrind, // 갈림 (강한 연속)
  tear, // 찢김
  burst, // 폭죽/터짐
  knotPop, // 톡 (매듭)
}

/// 추상 햅틱 엔진. "알림"이 아니라 촉감의 재현 — 연속/가변 강도가 핵심.
///
/// 구현 우선순위(TODO(haptics)):
///  - iOS: Core Haptics(CHHapticEngine) platform channel — 연속·가변 강도.
///  - Android: vibration 패키지 amplitude(API 26+).
///  - 폴백: FallbackHaptics(HapticFeedback). 웹·미지원 기기에서 무해.
/// 자세한 매핑은 .claude/skills/haptics-sensory/references/haptic-patterns.md 참조.
abstract class Haptics {
  /// 단발 패턴 재생. [intensity] 0~1.
  Future<void> play(HapticPattern pattern, {double intensity = 1.0});

  /// 연속 패턴 시작 (이후 [updateIntensity]로 실시간 강도 변조).
  Future<void> startContinuous(HapticPattern pattern);

  /// 진행 중인 연속 패턴의 강도 갱신. [value] 0~1.
  Future<void> updateIntensity(double value);

  /// 연속 패턴 정지.
  Future<void> stop();
}
