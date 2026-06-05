import 'package:flutter/widgets.dart';

import '../core/analytics.dart';

/// [AnalyticsService]를 위젯 트리에 노출한다.
/// 어느 화면에서든 `AnalyticsScope.of(context)`로 분석 호출.
class AnalyticsScope extends InheritedWidget {
  const AnalyticsScope({
    super.key,
    required this.analytics,
    required super.child,
  });

  final AnalyticsService analytics;

  static AnalyticsService of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<AnalyticsScope>();
    assert(scope != null, 'AnalyticsScope가 위젯 트리에 없습니다');
    return scope!.analytics;
  }

  @override
  bool updateShouldNotify(AnalyticsScope oldWidget) =>
      analytics != oldWidget.analytics;
}
