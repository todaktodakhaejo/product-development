import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'emotion_ball.dart';

/// 공 오브제 + 물결(누르기) + 쓰다듬기 발광을 그린다.
class EmotionBallPainter extends CustomPainter {
  EmotionBallPainter({
    required this.ball,
    required this.ripples,
    required this.strokeEnergy, // 쓰다듬기(GST-04) 누적 0~1
    required this.repaint,
  }) : super(repaint: repaint);

  final EmotionBall ball;
  final List<Ripple> ripples;
  final double strokeEnergy;
  final Listenable repaint;

  @override
  void paint(Canvas canvas, Size size) {
    // 물결 (누르기 GST-03)
    for (final r in ripples) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5 * r.life
        ..color = AppColors.ballGlow.withValues(alpha: 0.4 * r.life);
      canvas.drawCircle(r.center, r.radius, paint);
    }

    final scale = ball.scale;
    canvas.save();
    canvas.translate(ball.pos.dx, ball.pos.dy);
    canvas.scale(scale.dx, scale.dy);

    // 쓰다듬기 글로우 (GST-04) — 폭신하게 번지는 발광. 또렷한 링 금지.
    // alpha 0.2~0.4 * strokeEnergy 범위(§8), 부드러운 maskFilter blur.
    // 공 본체 뒤/주위에 깔리도록 외곽 발광보다 먼저, 더 넓게 그린다.
    final e = strokeEnergy.clamp(0.0, 1.0);
    if (e > 0.01) {
      final stroke = Paint()
        ..color = AppColors.ballGlow.withValues(alpha: (0.2 + 0.2 * e) * e)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 22 + 16 * e);
      canvas.drawCircle(Offset.zero, ball.radius * (1.18 + 0.22 * e), stroke);
    }

    // 외곽 발광
    final outerGlow = Paint()
      ..color = AppColors.ballGlow.withValues(alpha: 0.35)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18);
    canvas.drawCircle(Offset.zero, ball.radius * 1.05, outerGlow);

    // 본체: 부드러운 방사형 그라데이션
    final body = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.3, -0.35),
        colors: [
          Color.lerp(AppColors.ballCore, Colors.white, 0.35)!,
          AppColors.ballCore,
          AppColors.ballGlow,
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(Rect.fromCircle(center: Offset.zero, radius: ball.radius));
    canvas.drawCircle(Offset.zero, ball.radius, body);

    // 하이라이트
    final hi = Paint()..color = Colors.white.withValues(alpha: 0.5);
    canvas.drawCircle(
      Offset(-ball.radius * 0.32, -ball.radius * 0.36),
      ball.radius * 0.16,
      hi,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant EmotionBallPainter old) => false; // repaint로 갱신
}
