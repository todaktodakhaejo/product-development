import 'package:flutter/material.dart';

import 'models/ritual_session.dart';
import 'screens/soothe_page.dart';
import 'state/app_services.dart';
import 'theme/app_theme.dart';
import 'state/ritual_scope.dart';

/// 감정 오브제 명상 앱 루트.
///
/// 세션 상태([RitualSession])와 전역 서비스([AppServices])를 트리 최상단에
/// 노출하고, 진정 단계([SoothePage])로 시작한다.
class EmotionObjectApp extends StatefulWidget {
  const EmotionObjectApp({super.key});

  @override
  State<EmotionObjectApp> createState() => _EmotionObjectAppState();
}

class _EmotionObjectAppState extends State<EmotionObjectApp> {
  final RitualSession _session = RitualSession();
  final AppServices _services = AppServices.create();

  @override
  void dispose() {
    _session.dispose();
    _services.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppServicesScope(
      services: _services,
      child: RitualScope(
        session: _session,
        child: MaterialApp(
          title: '감정 오브제',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.theme,
          home: const SoothePage(),
        ),
      ),
    );
  }
}
