import 'package:flutter/material.dart';

import 'core/analytics.dart';
import 'core/haptics.dart';
import 'core/ritual_audio.dart';
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

  /// 앱 생명주기로 세션 경계를 잡고(분석 session_summary용), 백그라운드 진입 시
  /// 소리·진동을 전역 정지한다(#1: 앱을 꺼도 소리·진동·흔들기가 남지 않게).
  /// - 백그라운드(paused/hidden/detached): 세션 요약 전송 + 오디오 stopAll + 햅틱 suspend.
  /// - 포그라운드(resumed): 새 세션 시작 + 오디오·햅틱 재개(자동 재생은 하지 않음).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      widget.analytics.endSession();
      // 정지를 먼저 수행한 뒤(stopAll은 내부 suspend 게이트에 걸리기 전에 실행),
      // 이후 새 재생을 막도록 suspend 플래그를 세운다.
      RitualAudio.instance.stopAll();
      RitualAudio.instance.setSuspended(true);
      Haptics.instance.setSuspended(true);
    } else if (state == AppLifecycleState.resumed) {
      RitualAudio.instance.setSuspended(false);
      Haptics.instance.setSuspended(false);
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
