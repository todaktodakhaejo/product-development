import 'package:flutter/material.dart';

import 'features/onboarding/onboarding_screen.dart';
import 'state/session.dart';
import 'theme/app_theme.dart';

class EmotionResolutionApp extends StatefulWidget {
  const EmotionResolutionApp({super.key});

  @override
  State<EmotionResolutionApp> createState() => _EmotionResolutionAppState();
}

class _EmotionResolutionAppState extends State<EmotionResolutionApp> {
  late final SessionState _session = SessionState();

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SessionScope(
      notifier: _session,
      child: MaterialApp(
        title: '감정 해소',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark,
        home: const OnboardingScreen(),
      ),
    );
  }
}
