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
      final config = PostHogConfig(_apiKey)
        ..host = _host
        // 프라이버시: 자동 수집을 끄고 "우리가 정한 이벤트만" 수동 전송한다.
        // - 앱 생명주기 자동 이벤트 off(우리가 app_opened/session_started 직접 보냄)
        // - 세션 리플레이 off(화면 녹화·PII 위험 원천 차단)
        ..captureApplicationLifecycleEvents = false
        ..sessionReplay = false;
      await Posthog().setup(config);
      if (!enabled) await Posthog().disable();
    } catch (_) {
      // 분석 초기화 실패가 앱을 막지 않도록 무시.
    }
  }

  // ── 세션 요약(session_summary) 누적 지표 ──────────────────────────
  // 한 세션 동안 일어난 행동을 메모리에 모았다가, 세션이 끝날 때([endSession])
  // 1건으로 요약 전송한다. 개인정보·글 내용은 담지 않는다(글자 수만).
  DateTime? _sessionStart;
  String? _firstAction; // 'gesture' | 'writing' — 세션의 첫 행동
  int _totalGestureMs = 0; // 제스처 누적 시간(press/roll/rub)
  bool _textWritten = false;
  int _charCount = 0;
  String? _ritualType; // 선택/완료한 의식 종류

  /// 새 세션 시작점 기록(세션 지표 초기화). [sessionStarted] 전송과 함께 호출.
  void _beginSession() {
    _sessionStart = DateTime.now();
    _firstAction = null;
    _totalGestureMs = 0;
    _textWritten = false;
    _charCount = 0;
    _ritualType = null;
  }

  /// 현재 시각을 시간대 버킷으로(일출/낮/노을/밤/새벽). sky_background 앵커와 대략 일치.
  static String _timeBucket(DateTime now) {
    final h = now.hour;
    if (h >= 5 && h < 8) return 'dawn'; // 일출
    if (h >= 8 && h < 17) return 'day'; // 낮
    if (h >= 17 && h < 20) return 'dusk'; // 노을
    if (h >= 20 || h < 3) return 'night'; // 밤
    return 'predawn'; // 새벽(3~5)
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

  Future<void> sessionStarted() {
    _beginSession(); // 세션 지표 초기화(요약 누적 시작)
    return _capture('session_started');
  }

  Future<void> homeViewed() => _capture('home_viewed');

  /// 제스처 1회 수행. [gestureType]은 shake/press/roll/rub/stretch 등.
  /// [extra]로 제스처별 부가 지표(예: 늘리기의 peak_stretch)를 함께 보낼 수 있다
  /// (개인정보·글 내용은 금지 — 동작 지표만).
  Future<void> gesturePerformed(String gestureType, int durationMs,
      {Map<String, Object>? extra}) {
    _firstAction ??= 'gesture';
    if (durationMs > 0) _totalGestureMs += durationMs;
    final props = <String, Object>{
      'gesture_type': gestureType,
      'duration_ms': durationMs,
    };
    if (extra != null) props.addAll(extra);
    return _capture('gesture_performed', props);
  }

  Future<void> writingStarted() {
    _firstAction ??= 'writing';
    return _capture('writing_started');
  }

  /// 감정 글의 '내용'이 아니라 '글자 수'만 보낸다.
  Future<void> writingCompleted(int charCount) {
    _firstAction ??= 'writing';
    _textWritten = true;
    _charCount = charCount;
    return _capture('writing_completed', {'char_count': charCount});
  }

  Future<void> ritualSelected(String ritualType) {
    _ritualType = ritualType;
    return _capture('ritual_selected', {'ritual_type': ritualType});
  }

  Future<void> ritualCompleted(String ritualType) {
    _ritualType = ritualType;
    return _capture('ritual_completed', {'ritual_type': ritualType});
  }

  Future<void> completionViewed() => _capture('completion_viewed');

  /// 세션 종료 시 1건 요약(session_summary). 앱이 백그라운드로 갈 때 호출한다.
  /// 개인정보·글 내용 없음(글자 수만). 한 세션에 한 번만 전송하고 지표를 비운다.
  Future<void> endSession() async {
    final start = _sessionStart;
    if (start == null) return; // 시작 기록 없으면 스킵
    final now = DateTime.now();
    final props = <String, Object>{
      'first_action': _firstAction ?? 'none',
      'is_text_written': _textWritten,
      'char_count': _charCount,
      'total_gesture_ms': _totalGestureMs,
      'ritual_type': _ritualType ?? 'none',
      'time_bucket': _timeBucket(start),
      'duration_ms': now.difference(start).inMilliseconds,
    };
    _sessionStart = null; // 중복 전송 방지
    await _capture('session_summary', props);
  }
}
