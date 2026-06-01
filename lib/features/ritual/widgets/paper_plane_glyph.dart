import 'package:flutter/material.dart';

/// 종이비행기 다트 글리프(CustomPaint). **이모지 금지** — 접힌 종이 다트를 직접
/// 그린다. 접기 결과·비행 중·의식 선택 카드 아이콘 3곳에서 공통 사용한다.
///
/// 형태: 위(-y)가 코로 뾰족한 다트. 중앙 동체 keel(코→하단 중앙 세로선)을 경계로
/// 좌우 날개 면의 음영을 갈라 "접힌 V자" 입체감을 준다. 폭:높이 ≈ 1:1.25.
class PaperPlaneGlyph extends StatelessWidget {
  const PaperPlaneGlyph({super.key, this.size = 96, this.shadow = false});

  /// 정사각 박스 한 변. painter가 내부에서 1:1.25 비율로 다트를 배치한다.
  final double size;

  /// 가벼운 drop shadow(비행/결과 표시용). 카드 안 작은 아이콘은 false 권장.
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _PlanePainter(shadow: shadow),
      ),
    );
  }
}

/// 종이비행기 다트 painter. 색은 테마 토큰과 동일한 **로컬 const**로 둔다
/// (신규 색 토큰 추가 금지).
class _PlanePainter extends CustomPainter {
  _PlanePainter({required this.shadow});

  final bool shadow;

  // 테마(app_theme) 토큰과 동일 값을 painter 로컬 const로 보유(신규 토큰 추가 금지).
  static const Color _paper = Color(0xFFF6F1E7); // AppColors.paper — 밝은 면
  static const Color _paperShadow = Color(0xFFE7DEC9); // AppColors.paperShadow — 그늘 면
  static const Color _ink = Color(0xFF2B2B33); // AppColors.ink — keel·외곽 선

  @override
  void paint(Canvas canvas, Size size) {
    // 1:1.25 비율 박스를 정사각 size 안에 중앙 배치(여백 8%).
    final pad = size.width * 0.08;
    final boxW = size.width - pad * 2;
    final boxH = boxW * 1.25;
    final left = pad;
    final top = (size.height - boxH) / 2;

    // 논리 좌표(다트 폭 boxW, 높이 boxH).
    final cx = left + boxW / 2; // 동체 keel x(중앙).
    final noseY = top; // 코 꼭짓점(상단 중앙).
    final tailY = top + boxH; // 뒷전(하단).
    final keelBottomY = top + boxH * 0.96; // 동체 하단(살짝 위로 — 꼬리 갈라짐 표현).

    final halfW = boxW / 2;

    // 코(상단 중앙).
    final nose = Offset(cx, noseY);
    // 좌/우 날개 뒷전(하단 바깥).
    final tailL = Offset(left, tailY);
    final tailR = Offset(left + boxW, tailY);
    // 동체 하단 중앙(keel 아래 끝) — 날개 사이 V홈.
    final keelBottom = Offset(cx, keelBottomY);
    // 날개 뒷전 안쪽 노치(꼬리가 살짝 패인 다트 실루엣).
    final notchL = Offset(cx - halfW * 0.16, top + boxH * 0.82);
    final notchR = Offset(cx + halfW * 0.16, top + boxH * 0.82);

    // ── 그림자(선택) ──
    if (shadow) {
      final shadowPath = Path()
        ..moveTo(nose.dx, nose.dy)
        ..lineTo(tailR.dx, tailR.dy)
        ..lineTo(keelBottom.dx, keelBottom.dy)
        ..lineTo(tailL.dx, tailL.dy)
        ..close();
      canvas.drawPath(
        shadowPath.shift(const Offset(0, 6)),
        Paint()
          ..color = const Color(0x33000000)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );
    }

    // ── 좌측 날개 면(밝은 paper) ──
    // 코 → 동체 keel 하단 → 좌측 노치 → 좌측 뒷전 → 코.
    final leftWing = Path()
      ..moveTo(nose.dx, nose.dy)
      ..lineTo(keelBottom.dx, keelBottom.dy)
      ..lineTo(notchL.dx, notchL.dy)
      ..lineTo(tailL.dx, tailL.dy)
      ..close();
    canvas.drawPath(leftWing, Paint()..color = _paper);

    // ── 우측 날개 면(그늘 paperShadow) ──
    final rightWing = Path()
      ..moveTo(nose.dx, nose.dy)
      ..lineTo(keelBottom.dx, keelBottom.dy)
      ..lineTo(notchR.dx, notchR.dy)
      ..lineTo(tailR.dx, tailR.dy)
      ..close();
    canvas.drawPath(rightWing, Paint()..color = _paperShadow);

    // ── 외곽 미세 stroke(종이 가장자리 암시, ink 10%) ──
    final outline = Path()
      ..moveTo(nose.dx, nose.dy)
      ..lineTo(tailR.dx, tailR.dy)
      ..lineTo(notchR.dx, notchR.dy)
      ..lineTo(keelBottom.dx, keelBottom.dy)
      ..lineTo(notchL.dx, notchL.dy)
      ..lineTo(tailL.dx, tailL.dy)
      ..close();
    canvas.drawPath(
      outline,
      Paint()
        ..color = _ink.withValues(alpha: 0.10)
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.shortestSide * 0.008
        ..strokeJoin = StrokeJoin.round,
    );

    // ── 동체 keel 선(코→하단 중앙, ink 20%) — "접힌 V자" 경계 ──
    canvas.drawLine(
      nose,
      keelBottom,
      Paint()
        ..color = _ink.withValues(alpha: 0.20)
        ..strokeWidth = size.shortestSide * 0.012
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _PlanePainter old) => old.shadow != shadow;
}
