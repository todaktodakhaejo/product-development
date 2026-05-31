import 'package:flutter/services.dart';

import 'haptics.dart';

/// 모든 플랫폼에서 동작하는 폴백 햅틱. Flutter 내장 [HapticFeedback]만 사용한다.
///
/// 연속/가변 강도는 표현하지 못하므로, 본 구현은 단발 임팩트로 근사한다.
/// TODO(haptics): iOS Core Haptics / Android amplitude 구현체로 승급 시
/// [HapticsFactory]가 역량을 감지해 이 폴백 대신 선택하도록 한다.
class FallbackHaptics implements Haptics {
  @override
  Future<void> play(HapticPattern pattern, {double intensity = 1.0}) async {
    switch (pattern) {
      case HapticPattern.tapPop:
      case HapticPattern.knotPop:
        await HapticFeedback.lightImpact();
      case HapticPattern.rubTexture:
        await HapticFeedback.selectionClick();
      case HapticPattern.tear:
      case HapticPattern.shakeBounce:
      case HapticPattern.heartbeat:
        await HapticFeedback.mediumImpact();
      case HapticPattern.burst:
      case HapticPattern.shredGrind:
        await HapticFeedback.heavyImpact();
      case HapticPattern.pressHum:
        await HapticFeedback.lightImpact();
    }
  }

  // 폴백은 연속 진동을 지원하지 않는다. (no-op)
  // TODO(haptics): 네이티브 구현에서 연속/가변 강도를 채운다.
  @override
  Future<void> startContinuous(HapticPattern pattern) async {}

  @override
  Future<void> updateIntensity(double value) async {}

  @override
  Future<void> stop() async {}
}
