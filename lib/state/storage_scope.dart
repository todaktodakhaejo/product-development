import 'package:flutter/widgets.dart';

import '../services/storage_service.dart';

/// [StorageService]를 위젯 트리에 노출한다.
/// 어느 화면에서든 `StorageScope.of(context)`로 저장 레이어에 접근할 수 있다.
class StorageScope extends InheritedWidget {
  const StorageScope({
    super.key,
    required this.storage,
    required super.child,
  });

  final StorageService storage;

  static StorageService of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<StorageScope>();
    assert(scope != null, 'StorageScope가 위젯 트리에 없습니다');
    return scope!.storage;
  }

  @override
  bool updateShouldNotify(StorageScope oldWidget) =>
      storage != oldWidget.storage;
}
