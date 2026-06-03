import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:emotion_resolution_app/app.dart';
import 'package:emotion_resolution_app/services/storage_service.dart';

void main() {
  testWidgets('온보딩 첫 화면이 뜬다', (WidgetTester tester) async {
    // 저장소가 비어 있으면(처음 실행) 온보딩이 떠야 한다.
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.create();

    await tester.pumpWidget(EmotionResolutionApp(storage: storage));
    await tester.pump();

    // 온보딩 첫 페이지 카피 노출 확인
    expect(find.text('기록이 아니라, 해소'), findsOneWidget);
  });
}
