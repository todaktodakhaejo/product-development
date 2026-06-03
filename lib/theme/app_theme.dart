import 'package:flutter/material.dart';

/// 앱 전역 색상/그라데이션. 차분하고 위로가 되는 톤.
class AppColors {
  static const Color ink = Color(0xFF2B2B33);
  static const Color paper = Color(0xFFF6F1E7); // 종이 질감 베이스
  static const Color paperShadow = Color(0xFFE7DEC9);

  // 감정 오브제(공) 색
  static const Color ballCore = Color(0xFFB8C7FF);
  static const Color ballGlow = Color(0xFF8AA0E8);
  static const Color ballShade = Color(0xFF5A6AB0); // 구체 3D 음영용 짙은 쿨 라벤더

  // 배경 그라데이션 (밤하늘 톤, HOME-01 시간대 변화는 2차 스펙이라 단색 베이스)
  static const List<Color> bgGradient = [
    Color(0xFF1B2030),
    Color(0xFF2A2F45),
    Color(0xFF3A3550),
  ];

  static const Color emberOrange = Color(0xFFFF8A3D);
  static const Color emberYellow = Color(0xFFFFD36B);
}

class AppTheme {
  static ThemeData get dark {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: AppColors.bgGradient.first,
      textTheme: base.textTheme.apply(fontFamilyFallback: const ['Apple SD Gothic Neo', 'Noto Sans KR']),
      colorScheme: base.colorScheme.copyWith(
        primary: AppColors.ballGlow,
        surface: AppColors.bgGradient[1],
      ),
    );
  }
}

/// 화면 전체에 까는 부드러운 배경 그라데이션.
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child, this.colors});

  final Widget child;
  final List<Color>? colors;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: colors ?? AppColors.bgGradient,
        ),
      ),
      child: child,
    );
  }
}
