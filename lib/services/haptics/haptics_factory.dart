import 'fallback_haptics.dart';
import 'haptics.dart';

/// 런타임 기기 햅틱 역량을 감지해 적절한 [Haptics] 구현을 고른다(graceful degradation).
///
/// 현재는 폴백만 제공한다.
/// TODO(haptics): 분기 추가
///   if (iOS && supportsHaptics) -> IosCoreHaptics()
///   else if (Android && hasAmplitudeControl) -> AndroidAmplitudeHaptics()
///   else -> FallbackHaptics()
/// 설정에서 햅틱 OFF면 NoopHaptics() (호출부 API는 동일 유지).
class HapticsFactory {
  static Haptics create() {
    return FallbackHaptics();
  }
}
