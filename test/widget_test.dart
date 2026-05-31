import 'package:flutter_test/flutter_test.dart';

import 'package:emotion_resolution_app/app.dart';

void main() {
  testWidgets('온보딩 첫 화면이 뜬다', (WidgetTester tester) async {
    await tester.pumpWidget(const EmotionResolutionApp());
    await tester.pump();

    // 온보딩 첫 페이지 카피 노출 확인
    expect(find.text('기록이 아니라, 해소'), findsOneWidget);
  });
}
