import 'package:flutter/material.dart';

import 'app.dart';
import 'core/analytics.dart';
import 'services/storage_service.dart';

Future<void> main() async {
  // 저장소를 여는 동안(비동기) 잠깐 기다렸다가 앱을 시작한다.
  WidgetsFlutterBinding.ensureInitialized();
  final storage = await StorageService.create();

  // 분석(PostHog) 토대 — 실패해도 앱은 정상 동작.
  final analytics = AnalyticsService(storage);
  await analytics.init();
  await analytics.appOpened();
  await analytics.sessionStarted();

  runApp(EmotionResolutionApp(storage: storage, analytics: analytics));
}
