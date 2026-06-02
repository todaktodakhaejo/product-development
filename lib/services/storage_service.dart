import 'package:shared_preferences/shared_preferences.dart';

/// 앱의 영구 저장 레이어.
///
/// 기기 로컬 key-value 저장소(SharedPreferences)를 감싼다.
/// 화면 코드는 이 클래스의 의미 있는 메서드만 호출하고,
/// "어디에 어떻게 저장되는지"는 몰라도 된다. (나중에 DB로 바꿔도 화면은 그대로)
class StorageService {
  StorageService(this._prefs);

  final SharedPreferences _prefs;

  /// 앱 시작 시 한 번 호출해 저장소를 연 뒤 인스턴스를 만든다.
  static Future<StorageService> create() async {
    final prefs = await SharedPreferences.getInstance();
    return StorageService(prefs);
  }

  // 저장 키는 한 곳에서만 관리해 오타·중복을 막는다.
  static const _kOnboardingDone = 'onboarding_done';

  /// 온보딩을 이미 끝냈는지. 처음 실행이면 false.
  bool get onboardingDone => _prefs.getBool(_kOnboardingDone) ?? false;

  /// 온보딩 완료를 기록한다. 다음 실행부터 홈으로 직행하게 된다.
  Future<void> setOnboardingDone() => _prefs.setBool(_kOnboardingDone, true);
}
