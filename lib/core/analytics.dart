import 'package:posthog_flutter/posthog_flutter.dart';

import '../services/storage_service.dart';

/// 제품 분석(PostHog) 래퍼. 화면 코드는 의미 있는 메서드만 호출한다.
///
/// 프라이버시 원칙 (docs/ANALYTICS.md):
///  - 감정 글의 '내용'은 절대 전송하지 않는다 (글자 수만).
///  - 익명 식별만 사용 (PostHog 내장 anonymous id). 개인정보(PII) 금지.
///  - 옵트아웃: [setEnabled]로 끄면 그 즉시 전송 중단.
/// 분석은 어떤 경우에도 앱 동작을 막지 않는다(모든 호출을 try/catch로 보호).
class AnalyticsService {
  AnalyticsService(this._storage);

  final StorageService _storage;

  // PostHog Project API Key — `phc_`로 시작하는 공개키라 앱에 넣어도 안전.
  static const String _apiKey =
      'phc_rL4xbEAoGxPxbfgE7ZLvs77zDYBABEu6CPARPL56YD9B';
  static const String _host = 'https://us.i.posthog.com';

  bool get enabled => _storage.analyticsEnabled;

  /// 앱 시작 시 한 번 호출. PostHog를 초기화하고 옵트아웃 상태를 반영.
  Future<void> init() async {
    try {
      final config = PostHogConfig(_apiKey)..host = _host;
      await Posthog().setup(config);
      if (!enabled) await Posthog().disable();
    } catch (_) {
      // 분석 초기화 실패가 앱을 막지 않도록 무시.
    }
  }

  Future<void> _capture(String event, [Map<String, Object>? props]) async {
    if (!enabled) return;
    try {
      await Posthog().capture(eventName: event, properties: props);
    } catch (_) {}
  }

  /// 설정의 '사용 데이터 수집' 토글에서 호출 (옵트아웃/인).
  Future<void> setEnabled(bool value) async {
    await _storage.setAnalyticsEnabled(value);
    try {
      if (value) {
        await Posthog().enable();
      } else {
        await Posthog().disable();
      }
    } catch (_) {}
  }

  // ── 이벤트 (docs/ANALYTICS.md 택소노미) ──
  Future<void> appOpened() => _capture('app_opened');
  Future<void> sessionStarted() => _capture('session_started');

  Future<void> homeViewed() => _capture('home_viewed');
  Future<void> gesturePerformed(String gestureType, int durationMs) =>
      _capture('gesture_performed', {
        'gesture_type': gestureType,
        'duration_ms': durationMs,
      });

  Future<void> writingStarted() => _capture('writing_started');

  /// 감정 글의 '내용'이 아니라 '글자 수'만 보낸다.
  Future<void> writingCompleted(int charCount) =>
      _capture('writing_completed', {'char_count': charCount});

  Future<void> ritualSelected(String ritualType) =>
      _capture('ritual_selected', {'ritual_type': ritualType});
  Future<void> ritualCompleted(String ritualType) =>
      _capture('ritual_completed', {'ritual_type': ritualType});

  Future<void> completionViewed() => _capture('completion_viewed');
}
