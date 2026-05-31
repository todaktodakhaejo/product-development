import 'package:flutter/foundation.dart';

/// 햅틱/사운드 ON·OFF, 모션 민감도 설정.
///
/// 제품 철학: 무음·진동만 모드에서도 전체 경험이 성립해야 한다(PRODUCT_SPEC 2.6, 6장).
/// TODO(builder): shared_preferences로 영구화.
class SettingsService extends ChangeNotifier {
  bool _hapticsEnabled = true;
  bool _soundEnabled = true;
  double _motionSensitivity = 1.0; // 0~2, 1=기본

  bool get hapticsEnabled => _hapticsEnabled;
  bool get soundEnabled => _soundEnabled;
  double get motionSensitivity => _motionSensitivity;

  void setHaptics(bool value) {
    _hapticsEnabled = value;
    notifyListeners();
  }

  void setSound(bool value) {
    _soundEnabled = value;
    notifyListeners();
  }

  void setMotionSensitivity(double value) {
    _motionSensitivity = value.clamp(0.0, 2.0);
    notifyListeners();
  }
}
