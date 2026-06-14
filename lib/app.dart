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
      // 돌던 지속 루프(잔불·하늘 등)를 기억해 두고 모든 소리를 멈춘 뒤 재생을 막는다.
      RitualAudio.instance.suspendForBackground();
      Haptics.instance.setSuspended(true);
    } else if (state == AppLifecycleState.resumed) {
      Haptics.instance.setSuspended(false);
      // 백그라운드 직전 돌던 지속 사운드(잔불 타닥·하늘 두둥실)를 다시 재생한다(#1 후속).
      RitualAudio.instance.resumeFromBackground();
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
