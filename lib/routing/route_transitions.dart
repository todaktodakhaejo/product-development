import 'package:flutter/material.dart';

/// 단계 전환용 페이드 라우트. 하드 컷 금지(PRODUCT_SPEC 2.4).
///
/// TODO(motion): 공유 요소 morph 전환(오브제→종이 솟아오름 등)으로 고도화.
Route<T> fadeRoute<T>(Widget page) {
  return PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 600),
    reverseTransitionDuration: const Duration(milliseconds: 500),
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      return FadeTransition(
        opacity: CurvedAnimation(
          parent: animation,
          curve: Curves.easeInOutCubic,
        ),
        child: child,
      );
    },
  );
}
