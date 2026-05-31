import 'package:flutter/material.dart';

import 'app_colors.dart';

/// 앱 전역 테마. 파스텔 claymorphism 무드 + 여백 큰 한국어 타이포.
class AppTheme {
  static ThemeData get theme => ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: AppColors.bgGradientTop,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.buttonPrimary,
          brightness: Brightness.light,
          surface: AppColors.bgGradientTop,
        ),
        // TODO(builder): Pretendard 폰트를 assets/fonts에 번들 후 fontFamily 지정.
        textTheme: const TextTheme(
          // 단계 타이틀 18~20
          titleLarge: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 20,
            height: 1.5,
            fontWeight: FontWeight.w500,
            letterSpacing: -0.2,
          ),
          // 설명 카피 13~14
          bodyLarge: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 14,
            height: 1.7,
            fontWeight: FontWeight.w400,
          ),
          bodyMedium: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 13,
            height: 1.6,
          ),
          // 상태 미세 카피 11~12
          labelSmall: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12,
            height: 1.5,
          ),
        ),
      );
}
