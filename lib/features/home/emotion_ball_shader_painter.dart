import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'emotion_ball.dart';

/// 공을 3D 구처럼 그리는 프래그먼트 셰이더 painter.
///
/// shaders/ball.frag에 공 중심·반지름·멀티터치 함몰점을 넘겨, 누른 자리(들)가
/// 법선 변형 + 조명으로 "3D로 쏙 파이게" 렌더링한다(외곽은 항상 둥근 원).
/// 그 위/뒤에 캔버스 오버레이로 인터랙션 효과를 합친다 —
///   · 물결(누르기 GST-03): 본체 밖에서 퍼지는 링
///   · 쓰다듬기 글로우(GST-04): 본체 둘레 아우라 + 발광 링(공 뒤)
///   · 쓰다듬기 bloom: 손가락 닿는 자리를 따라다니는 화이트 발광(원형 안으로 clip)
/// 색·블렌드는 기존 EmotionBallPainter와 동일하게 맞춰 룩 일관성을 유지한다.
class EmotionBallShaderPainter extends CustomPainter {
  EmotionBallShaderPainter({
    required this.ball,
    required this.shader,
    required this.ripples,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final EmotionBall ball;
  final ui.FragmentShader shader;
  final List<Ripple> ripples;

  /// 셰이더가 받는 동시 함몰점 최대 개수(uTouch[15] = 5 × (x,y,depth)).
  static const int _maxTouch = 5;

  @override
  void paint(Canvas canvas, Size size) {
    final c = ball.pos;
    final r = ball.radius;
    // 두근거림(균일 펄스): ball.scale 평균(idle엔 ≈1±0.022).
    final s = ball.scale;
    final breathe = (s.dx + s.dy) * 0.5;
    // 일렁임 위상(라디안) — 느리게 도는 morphPhase 재사용.
    final time = ball.morphPhase;

    // ── 물결(누르기 GST-03) ──
    // 셰이더 본체 밖은 투명이라 먼저 그려도 본체 둘레로 퍼져 보인다.
    for (final rp in ripples) {
      final p = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5 * rp.life
        ..color = AppColors.jellyDeep.withValues(alpha: 0.4 * rp.life);
      canvas.drawCircle(rp.center, rp.radius, p);
    }

    // ── 쓰다듬기 글로우(본체 둘레 아우라 + 발광 링) ──
    // 공 뒤에 폭신하게 깔리도록 셰이더 본체보다 먼저 그린다(본체가 가운데를 덮음).
    // v17: 함몰·퍼짐과 같은 소스(strokeAmp)로 통일 — 문지르면 셋이 항상 같이 뜬다.
    final e = ball.strokeAmp.clamp(0.0, 1.0);
    if (e > 0.001) {
      final glowColor = Color.lerp(AppColors.jellyDeep, Colors.white, 0.5)!;
      // v18: 알파를 strokeAmp(e)에 "비례"(바닥값 없이 0부터)로 바꿔 손을 떼면 strokeAmp
      // 감쇠를 따라 매끄럽게 사라지게 한다(예전엔 0.22 바닥값이 임계에서 0으로 뚝 끊겼음).
      // (1) 넓고 옅게 번지는 바깥 아우라.
      final aura = Paint()
        ..color = glowColor.withValues(alpha: (0.52 * e).clamp(0.0, 0.55))
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 36 + 30 * e);
      canvas.drawCircle(c, r * (1.55 + 0.6 * e), aura);
      // (2) 본체 둘레에 더 또렷한 발광 링.
      final ring = Paint()
        ..color = glowColor.withValues(alpha: (0.72 * e).clamp(0.0, 0.85))
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 24 + 20 * e);
      canvas.drawCircle(c, r * (1.26 + 0.34 * e), ring);
    }

    // ── 3D 공 본체(셰이더): 멀티터치 함몰 + 조명 + 두근거림 + 일렁임 ──
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, c.dx)
      ..setFloat(3, c.dy)
      ..setFloat(4, r)
      ..setFloat(5, breathe)
      ..setFloat(6, time);

    // 멀티터치 함몰점: 주 누르기 + 추가 손가락(2번째~)을 모아 최대 5개를 채운다.
    // 빈 슬롯은 depth=0으로 채워 직전 프레임 잔상이 남지 않게 한다(셰이더는 무시).
    final points = ball.pressPoints;
    for (var i = 0; i < _maxTouch; i++) {
      final base = 7 + i * 3;
      if (i < points.length) {
        final pt = points[i];
        final abs = c + pt.contact; // 중심 기준 로컬좌표 → 절대좌표
        shader
          ..setFloat(base, abs.dx)
          ..setFloat(base + 1, abs.dy)
          ..setFloat(base + 2, pt.depth.clamp(0.0, 1.0));
      } else {
        shader
          ..setFloat(base, c.dx)
          ..setFloat(base + 1, c.dy)
          ..setFloat(base + 2, 0.0);
      }
    }

    // 문지르기 세기(22): 푸딩 swell + 일렁임 강화용.
    shader.setFloat(22, ball.strokeAmp.clamp(0.0, 1.0));

    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);

    // v17: 손가락 따라다니던 화이트 bloom은 제거했다 — 문지르기는 이제 셰이더의 이동
    // 함몰(pressPoints의 strokeContact 골 + 둘레 rim)이 3D로 직접 표현하므로, "빛만 따로
    // 움직여 어색하던" 효과는 뺀다. 둘레 글로우(위)는 은은한 분위기용으로 유지.
  }

  @override
  bool shouldRepaint(covariant EmotionBallShaderPainter oldDelegate) =>
      false; // repaint Listenable(_frame)로 매 프레임 갱신
}
