import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// 라벤더→페일핑크 그라데이션 배경 + 은은한 글로우. 모든 화면의 베이스.
///
/// [glowColor]로 의식별 강조색을 주입할 수 있다(없으면 기본 [AppColors.glow]).
class AppBackground extends StatelessWidget {
  const AppBackground({
    super.key,
    required this.child,
    this.glowColor,
  });

  final Widget child;
  final Color? glowColor;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.bgGradientTop, AppColors.bgGradientBottom],
        ),
      ),
      child: Stack(
        children: [
          // TODO(motion): blurred radial glow를 ImageFiltered/BackdropFilter로 고도화.
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, -0.35),
                    radius: 0.95,
                    colors: [
                      (glowColor ?? AppColors.glow).withValues(alpha: 0.35),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}
