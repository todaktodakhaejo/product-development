import 'package:flutter/material.dart';

import 'core/analytics.dart';
import 'features/home/home_screen.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'services/storage_service.dart';
import 'state/analytics_scope.dart';
import 'state/session.dart';
import 'state/storage_scope.dart';
import 'theme/app_theme.dart';

class EmotionResolutionApp extends StatefulWidget {
  const EmotionResolutionApp({
    super.key,
    required this.storage,
    required this.analytics,
  });

  final StorageService storage;
  final AnalyticsService analytics;

  @override
  State<EmotionResolutionApp> createState() => _EmotionResolutionAppState();
}

class _EmotionResolutionAppState extends State<EmotionResolutionApp>
    with WidgetsBindingObserver {
  late final SessionState _session = SessionState();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  /// 앱 생명주기로 세션 경계를 잡는다(분석 session_summary용).
  /// - 백그라운드(paused)로 가면 현재 세션을 1건으로 요약 전송.
  /// - 다시 포그라운드(resumed)로 오면 새 세션 시작(session_started).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      widget.analytics.endSession();
    } else if (state == AppLifecycleState.resumed) {
      widget.analytics.sessionStarted();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StorageScope(
      storage: widget.storage,
      child: AnalyticsScope(
        analytics: widget.analytics,
        child: SessionScope(
          notifier: _session,
        child: MaterialApp(
          title: '감정 해소',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark,
          // 온보딩을 이미 봤으면 홈으로 직행, 처음이면 온보딩부터.
          home: widget.storage.onboardingDone
              ? const HomeScreen()
              : const OnboardingScreen(),
        ),
      ),
      ),
    );
  }
}
