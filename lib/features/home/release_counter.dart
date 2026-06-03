import 'package:shared_preferences/shared_preferences.dart';

/// 흘려보낸(의식 완료) 누적 횟수의 영구 저장소.
///
/// storage_service.dart(P2/P3 소유)를 건드리지 않기 위해 홈 전용으로
/// SharedPreferences를 직접 사용한다. 키는 'release_count' 단일.
class ReleaseCounter {
  ReleaseCounter._();

  /// SharedPreferences 키. 앱 전역에서 이 카운트만의 고유 키.
  static const String _key = 'release_count';

  /// 현재까지 흘려보낸 누적 횟수를 읽는다(없으면 0).
  static Future<int> read() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_key) ?? 0;
  }

  /// 누적 횟수를 1 늘리고 새 값을 반환한다(의식 완료 시 1회 호출).
  static Future<int> increment() async {
    final prefs = await SharedPreferences.getInstance();
    final next = (prefs.getInt(_key) ?? 0) + 1;
    await prefs.setInt(_key, next);
    return next;
  }
}
