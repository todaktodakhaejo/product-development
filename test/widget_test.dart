// 감정 오브제 명상 앱 — 진정 화면 스모크 테스트.
import 'package:flutter_test/flutter_test.dart';

import 'package:emotion_relief/app.dart';
import 'package:emotion_relief/widgets/blob_object.dart';

void main() {
  testWidgets('앱이 진정(Soothe) 화면으로 시작한다', (WidgetTester tester) async {
    await tester.pumpWidget(const EmotionObjectApp());
    await tester.pump(); // 첫 프레임

    // 진정 단계 카피와 오브제가 보인다.
    expect(find.textContaining('진정시켜요'), findsOneWidget);
    expect(find.byType(BlobObject), findsOneWidget);
  });
}
