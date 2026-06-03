import 'dart:math';

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
    // 누르기 홀드 덴트(GST-03, v3 §2): 홀드로 깊이가 1까지 커지므로 깊게 침몰해도
    // 어두운 inner shadow 대신 본체 변형(납작+부풀음) + 하이라이트 이동 + 화이트
    // bloom으로 claymorphism 말랑함을 유지한다. "손가락에 점토가 밀려 눌리는" 느낌.
    final pd = ball.pressDepth.clamp(0.0, 1.0);
    // pressDir = 누른 지점→중심 방향. 덴트는 그 반대(손가락 쪽)로 들어간다.
    final dent = pd > 0.001 ? -ball.pressDir : Offset.zero;

    canvas.save();
    canvas.translate(ball.pos.dx, ball.pos.dy);
    canvas.scale(scale.dx, scale.dy);
    if (pd > 0.001) {
      // 덴트 축으로 눌리고 직교축으로 부푸는 추가 squash(깊은 홀드까지 수용해
      // along 0.26까지·cross 0.16까지 — 깊어도 말랑하게 부풀어 넘침).
      // v4 §2: 가로/세로 스냅(if horizontal) 제거 → pressDir 임의 각도로 회전 변형.
      // pressDir 축으로 회전해 그 축을 x축에 정렬한 뒤 along(압축)·cross(부풀음)를
      // 적용하고 되돌린다. 대각선에서 눌러도 그 방향으로 정확히 납작해진다.
      final along = 1 - pd * 0.26; // pressDir축 압축
      final cross = 1 + pd * 0.16; // 직교축 부풀음
      final ang = atan2(ball.pressDir.dy, ball.pressDir.dx);
      canvas.rotate(ang);
      canvas.scale(along, cross);
      canvas.rotate(-ang);
      // 손가락 쪽으로 본체를 미세 이동(들어가는 방향감, 깊이 비례 0.16까지).
      canvas.translate(dent.dx * ball.radius * 0.16 * pd,
          dent.dy * ball.radius * 0.16 * pd);
    }

    // 쓰다듬기 글로우 (GST-04) — 폭신하게 번지는 발광. 또렷한 링 금지.
    // alpha 0.2~0.4 * strokeEnergy 범위(§8), 부드러운 maskFilter blur.
    // 공 본체 뒤/주위에 깔리도록 외곽 발광보다 먼저, 더 넓게 그린다.
    // v2: 상한만 소폭 상향(alpha 0.45까지, blur 24+18e). "또렷해지지 않게" 우선,
    // 은은하게 더 번지는 정도(§9). 새 색 토큰 없이 ballGlow 재사용.
    // v5 §2: 쓰다듬기를 확실히 인지시키기 위해 글로우를 더 또렷이 번지게 —
    // alpha 상한 0.45→0.55, 계수 소폭↑(0.26+0.26e), 반경 계수 1.18+0.24e→1.20+0.28e.
    // blur는 24+18e 유지 → 링/하드엣지 없이 폭신하게 차오르는 발광만 강화.
    final e = strokeEnergy.clamp(0.0, 1.0);
    if (e > 0.01) {
      final stroke = Paint()
        ..color = AppColors.ballGlow
            .withValues(alpha: ((0.26 + 0.26 * e) * e).clamp(0.0, 0.55))
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 24 + 18 * e);
      canvas.drawCircle(Offset.zero, ball.radius * (1.20 + 0.28 * e), stroke);
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

    // v9 §3: 구체 3D 음영(터미네이터). 본체 하단~우하단에 팔레트 내 살짝 짙은
    // 쿨톤(ballGlow를 더 짙은 라벤더로 살짝 lerp)을 두 번째 RadialGradient로 덧칠 —
    // 빛(top-left) 반대쪽이 어둑해 "빛 받는 구슬"로 읽히게. 검은색 금지·저대비:
    // 가장 짙은 곳도 알파 0.5 미만, 중심은 투명이라 본체 밝기를 해치지 않는다.
    // _coolShade = ballGlow를 ballCore의 보색쪽이 아니라 더 깊은 쿨 라벤더로 0.55 lerp.
    final coolShade = Color.lerp(
        AppColors.ballGlow, AppColors.ballShade, 0.55)!; // 짙은 쿨 라벤더
    final shade = Paint()
      ..shader = RadialGradient(
        // 빛 반대쪽(우하단)을 음영 중심으로 — 본체 하단~우하단이 어둑.
        center: const Alignment(0.42, 0.55),
        radius: 1.05,
        colors: [
          coolShade.withValues(alpha: 0.42), // 우하단: 부드러운 음영
          coolShade.withValues(alpha: 0.16),
          coolShade.withValues(alpha: 0.0), // 빛 쪽: 투명
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromCircle(center: Offset.zero, radius: ball.radius))
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawCircle(Offset.zero, ball.radius, shade);

    // 하이라이트 — 누르기 중엔 덴트 쪽으로 끌려가 본체가 휘어 보이게(깊을수록 더).
    final hiBase = Offset(-ball.radius * 0.32, -ball.radius * 0.36);
    final hiPos = pd > 0.001
        ? hiBase + dent * (ball.radius * 0.20 * pd)
        : hiBase;
    final hi = Paint()
      ..color = Colors.white.withValues(alpha: 0.5)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    canvas.drawCircle(hiPos, ball.radius * 0.16, hi);

    // v9 §3: 작고 또렷한 스펙큘러 화이트 광택(top-left) — 구슬의 광원 반사점.
    // 위 넓은 하이라이트보다 안쪽·집중. blur 최소로 또렷하되 하드엣지는 아님.
    // 누르기 중엔 넓은 하이라이트와 같은 비율로 덴트 쪽을 따라가 표면 휘어짐과 일관.
    final specBase = Offset(-ball.radius * 0.38, -ball.radius * 0.42);
    final specPos = pd > 0.001
        ? specBase + dent * (ball.radius * 0.20 * pd)
        : specBase;
    final spec = Paint()
      ..color = Colors.white.withValues(alpha: 0.7)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5);
    canvas.drawCircle(specPos, ball.radius * 0.07, spec);

    // 누르기 접촉부 부드러운 광택(어두운 음영 대신 밝게 번지는 점토 눌림감).
    // dent 방향(손가락 쪽) 표면에 은은한 화이트 bloom — 또렷한 링 금지.
    // 깊은 홀드(pd→1)에서도 어둡지 않게: 밝기·번짐만 키워 "눌려도 보송한" 점토감.
    if (pd > 0.001) {
      final contact = dent * (ball.radius * (0.42 + 0.12 * pd));
      final dimple = Paint()
        ..color = Colors.white.withValues(alpha: (0.20 + 0.16 * pd).clamp(0.0, 0.36))
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 10 + 14 * pd);
      canvas.drawCircle(contact, ball.radius * (0.34 + 0.10 * pd), dimple);
    }

    // v9 §4: 손가락 닿은 자리에 "뽁" 국소 오목 덴트 — pressContact 위치에 그린다.
    // 위 dent(축 방향 본체 휘어짐)와 공존하되, 이건 접촉점 그 자리가 안으로 쑥
    // 들어간 듯한 국소 오목감을 만든다. 깊이·크기 모두 pressDepth 비례.
    // 광원은 top-left(스펙큘러와 동일)로 가정.
    if (pd > 0.001) {
      final c = ball.pressContact;
      final dentR = ball.radius * (0.26 + 0.14 * pd); // 오목 반경(깊을수록 넓게)
      // (1) 안쪽 부드러운 오목 음영 — 팔레트 내 짙은 쿨톤, 저알파, blur.
      //     표면이 안으로 들어가 광원을 덜 받는 느낌. 검은색·하드엣지 금지.
      //     음영 중심을 살짝 광원 쪽(top-left)으로 치우쳐 오목 바닥의 그늘을 암시.
      final shadeOffset = const Offset(-0.12, -0.14) * (ball.radius * pd);
      final concave = Paint()
        ..color = coolShade.withValues(alpha: (0.16 + 0.22 * pd).clamp(0.0, 0.40))
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 6 + 10 * pd);
      canvas.drawCircle(c + shadeOffset, dentR, concave);
      // (2) 둘레(빛 반대쪽=우하단)에 얇은 림 하이라이트 — 오목 입체의 경계.
      //     오목한 벽이 광원을 향해 살짝 솟아 빛을 받는 가장자리. white 저알파, 가는 stroke.
      final rim = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = (1.2 + 1.6 * pd).clamp(1.0, 3.0)
        ..color = Colors.white.withValues(alpha: (0.10 + 0.20 * pd).clamp(0.0, 0.32))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5);
      // 빛 반대쪽(우하단) 호만 강조되도록 림 중심을 우하단으로 살짝 밀어 그린다.
      final rimOffset = const Offset(0.10, 0.12) * (ball.radius * pd);
      canvas.drawCircle(c + rimOffset, dentR * 0.96, rim);
    }

    // 쓰다듬기 위치 반응(GST-04, v8 §1-B) — 손가락 닿는 자리를 따라다니는 광택.
    // 전역 strokeEnergy 글로우(본체 뒤 은은한 발광)와 달리, 이건 본체 표면 위
    // strokeContact 위치에 그려지는 국소 화이트 bloom. canvas는 이미 본체 중심으로
    // translate/scale된 상태이므로 strokeContact(중심 기준 로컬좌표)를 그대로 사용
    // (scale 보정은 근사 허용). 어두운 음영·또렷한 링 금지 — 부드러운 blur만.
    final sa = ball.strokeAmp.clamp(0.0, 1.0);
    if (sa > 0.01) {
      final bloom = Paint()
        ..color = Colors.white
            .withValues(alpha: (0.10 + 0.18 * sa).clamp(0.0, 0.30))
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 12 + 10 * sa);
      canvas.drawCircle(ball.strokeContact, ball.radius * (0.26 + 0.06 * sa), bloom);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant EmotionBallPainter old) => false; // repaint로 갱신
}
