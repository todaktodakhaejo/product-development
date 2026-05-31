import 'package:flutter/material.dart';

/// 디자인 시스템 컬러 토큰 (docs/PRODUCT_SPEC.md 2.2).
///
/// 화면 코드에서 HEX를 직접 쓰지 말고 이 세만틱 토큰을 사용한다.
/// 한 화면 = 배경 그라데이션 + 의식별 단일 강조색 원칙.
abstract class AppColors {
  // 배경
  static const Color bgGradientTop = Color(0xFFC7BEDD); // 라벤더
  static const Color bgGradientBottom = Color(0xFFEBDCE0); // 페일 핑크

  // 오브제 (claymorphism 3톤)
  static const Color objectCore = Color(0xFFE59FB0); // 음영/코어
  static const Color objectBase = Color(0xFFF2BCC8); // 메인 면
  static const Color objectHighlight = Color(0xFFFBE3E8); // 하이라이트

  // 빛
  static const Color glow = Color(0xFFFFD9E0);

  // 종이
  static const Color paper = Color(0xFFF3ECDF);
  static const Color paperLine = Color(0xFFDED3C2);

  // 텍스트
  static const Color textPrimary = Color(0xFF4A4458);
  static const Color textSecondary = Color(0xFF8A8398);

  // 의식 선택 카드
  static const Color cardTop = Color(0xFF9C8FB8);
  static const Color cardBottom = Color(0xFFB7ABC9);

  // 버튼
  static const Color buttonPrimary = Color(0xFF9685B5);

  // 의식별 강조 (예: 모닥불)
  static const Color accentFireHot = Color(0xFFFF8A4C);
  static const Color accentFireWarm = Color(0xFFFFC15E);
}
