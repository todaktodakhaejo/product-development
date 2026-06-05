import 'package:shared_preferences/shared_preferences.dart';

/// 홈 전용 영구 카운터 저장소(2종).
///
/// storage_service.dart(P2/P3 소유)를 건드리지 않기 위해 홈 전용으로
/// SharedPreferences를 직접 사용한다.
///  - 'release_count'    : 흘려보낸(의식 완료) 누적 횟수. 의식 완료 시 +1.
///  - 'interaction_count': 공 놀이(튕김·흔듦·굴림·만짐·누름) 평생 누적 횟수.
///
/// interaction_count는 매 제스처마다 디스크 쓰기를 하지 않는다(쓰기 폭주 방지).
/// 시작 시 [readInteraction]으로 lifetime 값을 메모리에 로드해 화면에서 증가시키고,
/// 실제 디스크 반영은 [saveInteraction] 디바운스 호출(주기 Timer/의식 완료/dispose)에서만 한다.
class ReleaseCounter {
  ReleaseCounter._();

  /// 흘려보냄(의식 완료) 누적 횟수 키.
  static const String _key = 'release_count';

  /// 공 놀이(인터랙션) 평생 누적 횟수 키.
  static const String _interactionKey = 'interaction_count';

  /// 현재까지 흘려보낸 누적 횟수를 읽는다(없으면 0).
  static Future<int> read() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_key) ?? 0;
  }

  /// 흘려보냄 누적 횟수를 1 늘리고 새 값을 반환한다(의식 완료 시 1회 호출).
  static Future<int> increment() async {
    final prefs = await SharedPreferences.getInstance();
    final next = (prefs.getInt(_key) ?? 0) + 1;
    await prefs.setInt(_key, next);
    return next;
  }

  /// 공 놀이 평생 누적 횟수를 읽는다(없으면 0). 화면 진입 시 1회 로드용.
  static Future<int> readInteraction() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_interactionKey) ?? 0;
  }

  /// 메모리에서 누적된 공 놀이 횟수를 디스크에 반영한다(디바운스 호출 전용).
  ///
  /// 매 제스처가 아니라 주기 Timer/의식 완료/dispose 시점에서만 호출해
  /// 쓰기 빈도를 낮춘다. 동일 값이면 setInt가 사실상 no-op이라 안전하다.
  static Future<void> saveInteraction(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_interactionKey, value);
  }
}
