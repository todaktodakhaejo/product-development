import 'package:flutter/material.dart';

import '../models/ritual_session.dart';

/// [RitualSession]을 위젯 트리 어디서든 꺼내 쓰기 위한 InheritedNotifier.
///
/// 외부 상태관리 패키지 없이 동작한다.
/// TODO(builder): 규모가 커지면 Provider/Riverpod로 교체 검토 (PRODUCT_SPEC 6장).
class RitualScope extends InheritedNotifier<RitualSession> {
  const RitualScope({
    super.key,
    required RitualSession session,
    required super.child,
  }) : super(notifier: session);

  static RitualSession of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<RitualScope>();
    assert(scope != null, 'RitualScope를 찾을 수 없습니다.');
    return scope!.notifier!;
  }
}
