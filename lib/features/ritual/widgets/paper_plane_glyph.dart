import 'package:flutter/material.dart';

/// 종이비행기 글라이더 글리프(CustomPaint). **이모지 금지** — 접힌 종이 비행기를
/// 직접 그린다. 접기 결과·비행 중·의식 선택 카드 아이콘 3곳에서 공통 사용한다.
///
/// 형태: 레퍼런스(종이접기 튜토리얼)의 **글라이더형** — 위(-y)가 뾰족한 다트가
/// 아니라 **뭉툭(평평)한 코** + **넓고 평평한 날개**의 안정형. 코 끝은 작은 수평
/// 단면(noseL→noseR)으로 평평하고, 그 아래 무게 실린 사다리꼴 머리(삼각 코를
/// 아래로 접어 내린 자국)를 둔다. 중앙 동체 keel(코→하단 중앙 세로선)을 경계로
/// 좌우 날개 면의 음영을 갈라 "접힌 V자" 입체감을 준다. 폭:높이 ≈ 1.18:1(넓적).
class PaperPlaneGlyph extends StatelessWidget {
  const PaperPlaneGlyph({super.key, this.size = 96, this.shadow = false});

  /// 정사각 박스 한 변. painter가 내부에서 글라이더 비율로 비행기를 배치한다.
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

/// 종이비행기 글라이더의 기하 정점(논리 좌표). glyph painter와 접기 모핑
/// 페인터(_FoldMorphPainter)가 **동일 비율**을 공유해 progress=1에서 끝 모양이
/// 정확히 일치하도록, 모든 정점을 한 곳에서 산출한다.
///
/// 넓적한 1.18:1(폭:높이) 박스를 정사각 `size` 안에 중앙 배치(여백 7%)한 기준.
/// 레퍼런스의 **뭉툭한 코**: 단일 점이 아니라 코 폭(noseHalf)을 가진 짧은
/// 수평 단면(noseL→noseR)으로 평평하다.
class PaperPlaneDartGeometry {
  PaperPlaneDartGeometry._({
    required this.noseL,
    required this.noseR,
    required this.tailL,
    required this.tailR,
    required this.keelBottom,
    required this.notchL,
    required this.notchR,
    required this.box,
  });

  final Offset noseL; // 뭉툭한 코 평평 단면 좌끝.
  final Offset noseR; // 뭉툭한 코 평평 단면 우끝.
  final Offset tailL; // 좌측 날개 뒷전(하단 바깥) — 넓게.
  final Offset tailR; // 우측 날개 뒷전(하단 바깥) — 넓게.
  final Offset keelBottom; // 동체 하단 중앙(keel 끝, 날개 사이 V홈).
  final Offset notchL; // 좌측 꼬리 안쪽 노치.
  final Offset notchR; // 우측 꼬리 안쪽 노치.
  final Rect box; // 비행기가 배치된 박스(접기 시작 사각형 참조용).

  /// 코 중앙(평평 단면의 중점) — keel·동체 정렬 기준.
  Offset get noseMid => Offset((noseL.dx + noseR.dx) / 2, noseL.dy);

  /// 정사각 `size` 박스에 맞춘 글라이더 정점을 산출한다.
  factory PaperPlaneDartGeometry.forSquare(Size size) {
    final pad = size.width * 0.07;
    final boxW = size.width - pad * 2;
    final boxH = boxW / 1.18; // 넓적(폭 > 높이) — 글라이더 실루엣.
    final left = pad;
    final top = (size.height - boxH) / 2;

    final cx = left + boxW / 2; // 동체 keel x(중앙).
    final noseY = top; // 코 평평 단면(상단 중앙).
    final tailY = top + boxH; // 뒷전(하단).
    final keelBottomY = top + boxH * 0.94; // 동체 하단(살짝 위 — 꼬리 갈라짐).
    final halfW = boxW / 2;
    // 코 평평 폭: 박스 폭의 11%(좌우 합) — 뾰족하지 않게 뭉툭한 단면.
    final noseHalf = boxW * 0.055;

    return PaperPlaneDartGeometry._(
      noseL: Offset(cx - noseHalf, noseY),
      noseR: Offset(cx + noseHalf, noseY),
      tailL: Offset(left, tailY),
      tailR: Offset(left + boxW, tailY),
      keelBottom: Offset(cx, keelBottomY),
      notchL: Offset(cx - halfW * 0.18, top + boxH * 0.80),
      notchR: Offset(cx + halfW * 0.18, top + boxH * 0.80),
      box: Rect.fromLTWH(left, top, boxW, boxH),
    );
  }
}

/// 종이비행기 글라이더 painter. 색은 테마 토큰과 동일한 **로컬 const**로 둔다
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
    // 글라이더 정점을 공유 기하에서 산출(접기 모핑 페인터와 끝 모양 일치).
    final g = PaperPlaneDartGeometry.forSquare(size);
    final noseL = g.noseL;
    final noseR = g.noseR;
    final tailL = g.tailL;
    final tailR = g.tailR;
    final keelBottom = g.keelBottom;
    final notchL = g.notchL;
    final notchR = g.notchR;

    // ── 그림자(선택) ──
    // 외곽(뭉툭 코 평평 단면 포함)을 그대로 따른다.
    if (shadow) {
      final shadowPath = Path()
        ..moveTo(noseL.dx, noseL.dy)
        ..lineTo(noseR.dx, noseR.dy)
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
    // 코 좌끝 → 동체 keel 하단 → 좌측 노치 → 좌측 뒷전 → 코 좌끝.
    final leftWing = Path()
      ..moveTo(noseL.dx, noseL.dy)
      ..lineTo(keelBottom.dx, keelBottom.dy)
      ..lineTo(notchL.dx, notchL.dy)
      ..lineTo(tailL.dx, tailL.dy)
      ..close();
    canvas.drawPath(leftWing, Paint()..color = _paper);

    // ── 우측 날개 면(그늘 paperShadow) ──
    final rightWing = Path()
      ..moveTo(noseR.dx, noseR.dy)
      ..lineTo(keelBottom.dx, keelBottom.dy)
      ..lineTo(notchR.dx, notchR.dy)
      ..lineTo(tailR.dx, tailR.dy)
      ..close();
    canvas.drawPath(rightWing, Paint()..color = _paperShadow);

    // ── 뭉툭 코 머리 음영(평평 단면 아래 작은 사다리꼴) ──
    // 삼각 코를 아래로 접어 내린 자국 — keel 양쪽에 옅은 그늘로 무게감을 준다.
    final headY = keelBottom.dy * 0.0 + (noseL.dy + (keelBottom.dy - noseL.dy) * 0.30);
    final headL = Offset(noseL.dx - (noseR.dx - noseL.dx) * 0.35, headY);
    final headR = Offset(noseR.dx + (noseR.dx - noseL.dx) * 0.35, headY);
    final head = Path()
      ..moveTo(noseL.dx, noseL.dy)
      ..lineTo(noseR.dx, noseR.dy)
      ..lineTo(headR.dx, headR.dy)
      ..lineTo(headL.dx, headL.dy)
      ..close();
    canvas.drawPath(head, Paint()..color = _paperShadow.withValues(alpha: 0.55));
    // 코 접힘선(평평 단면) — 뭉툭함을 또렷이.
    canvas.drawLine(
      headL,
      headR,
      Paint()
        ..color = _ink.withValues(alpha: 0.10)
        ..strokeWidth = size.shortestSide * 0.007
        ..strokeCap = StrokeCap.round,
    );

    // ── 외곽 미세 stroke(종이 가장자리 암시, ink 10%) ──
    final outline = Path()
      ..moveTo(noseL.dx, noseL.dy)
      ..lineTo(noseR.dx, noseR.dy)
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

    // ── 동체 keel 선(코 중앙→하단 중앙, ink 20%) — "접힌 V자" 경계 ──
    canvas.drawLine(
      g.noseMid,
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
