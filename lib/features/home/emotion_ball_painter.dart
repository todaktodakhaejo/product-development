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
    // 누르기 덴트(GST-03): 본체를 덴트 축으로 살짝 납작하게(푸딩 squash) +
    // 손가락 쪽으로 본체를 미세 이동시켜 "쑤욱 들어간" 느낌. 어두운 inner shadow
    // 대신 본체 변형 + 하이라이트 이동으로 claymorphism 말랑함을 유지한다(§9).
    final pd = ball.pressDepth.clamp(0.0, 1.0);
    // pressDir = 탭 지점→중심 방향. 덴트는 그 반대(손가락 쪽)로 들어간다.
    final dent = pd > 0.001 ? -ball.pressDir : Offset.zero;

    canvas.save();
    canvas.translate(ball.pos.dx, ball.pos.dy);
    canvas.scale(scale.dx, scale.dy);
    if (pd > 0.001) {
      // 덴트 축으로 눌리고 직교축으로 부푸는 추가 squash(전체 0.16까지).
      final along = 1 - pd * 0.16;
      final cross = 1 + pd * 0.10;
      final horizontal = ball.pressDir.dx.abs() > ball.pressDir.dy.abs();
      if (horizontal) {
        canvas.scale(along, cross);
      } else {
        canvas.scale(cross, along);
      }
      // 손가락 쪽으로 본체를 미세 이동(들어가는 방향감).
      canvas.translate(dent.dx * ball.radius * 0.10 * pd,
          dent.dy * ball.radius * 0.10 * pd);
    }

    // 쓰다듬기 글로우 (GST-04) — 폭신하게 번지는 발광. 또렷한 링 금지.
    // alpha 0.2~0.4 * strokeEnergy 범위(§8), 부드러운 maskFilter blur.
    // 공 본체 뒤/주위에 깔리도록 외곽 발광보다 먼저, 더 넓게 그린다.
    // v2: 상한만 소폭 상향(alpha 0.45까지, blur 24+18e). "또렷해지지 않게" 우선,
    // 은은하게 더 번지는 정도(§9). 새 색 토큰 없이 ballGlow 재사용.
    final e = strokeEnergy.clamp(0.0, 1.0);
    if (e > 0.01) {
      final stroke = Paint()
        ..color = AppColors.ballGlow
            .withValues(alpha: ((0.22 + 0.23 * e) * e).clamp(0.0, 0.45))
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 24 + 18 * e);
      canvas.drawCircle(Offset.zero, ball.radius * (1.18 + 0.24 * e), stroke);
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

    // 하이라이트 — 누르기 중엔 덴트 쪽으로 살짝 끌려가 본체가 휘어 보이게.
    final hiBase = Offset(-ball.radius * 0.32, -ball.radius * 0.36);
    final hiPos = pd > 0.001
        ? hiBase + dent * (ball.radius * 0.14 * pd)
        : hiBase;
    final hi = Paint()..color = Colors.white.withValues(alpha: 0.5);
    canvas.drawCircle(hiPos, ball.radius * 0.16, hi);

    // 누르기 접촉부 부드러운 광택(어두운 음영 대신 밝게 번지는 점토 눌림감, §9).
    // dent 방향(손가락 쪽) 표면에 은은한 화이트 bloom — 또렷한 링 금지.
    if (pd > 0.001) {
      final contact = dent * (ball.radius * 0.5);
      final dimple = Paint()
        ..color = Colors.white.withValues(alpha: 0.22 * pd)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 10 + 8 * pd);
      canvas.drawCircle(contact, ball.radius * 0.34, dimple);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant EmotionBallPainter old) => false; // repaint로 갱신
}
