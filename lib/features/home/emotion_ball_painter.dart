import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'emotion_ball.dart';

/// 공 오브제(슬라임/탱탱볼) + 물결(누르기) + 쓰다듬기 발광을 그린다.
///
/// v11(§A): 프로토타입 JellyBall 느낌으로 시각 표현을 리워크 —
/// 1) 본체 radial(white→jellyCore→jellyEdge) + 젤 inset 음영(어두운 우하단/
///    밝은 좌상단) + 외곽 drop 글로우. 2) 완전 원이 아닌 유기적 blob(미세 모핑).
/// 3) idle 호흡 출렁임(EmotionBall.scale에 합성). 4) 누르기 = 넓고 납작 splat +
///    손가락 딤플 + 떼면 스프링 오버슈트(통통). 5) 쓰다듬기 = 표면이 손가락
///    속도 방향으로 흐르듯 stretch+skew. 색은 jelly*/#E08AA6/white/지정 rgba만.
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

  // 젤 inset 음영색(프로토타입 box-shadow inset 값, 검정 금지).
  static const Color _jelInsetDark = Color(0xFFC16080); // rgba(193,96,128) 우하단
  // 외곽 drop 글로우색 rgba(231,155,176).
  static const Color _jelDropGlow = Color(0xFFE79BB0);
  // 손가락 딤플 음영색 rgba(150,70,95).
  static const Color _dimpleShade = Color(0xFF96465F);

  // ── blob 경로 캐시(v12 §2: 매 프레임 베지어 재계산 회피) ──────────────
  // 유기적 blob은 morphPhase가 0.967rad/s로 "아주 천천히" 도는 미세 모핑이라
  // 매 프레임 풀 재계산이 필요 없다. phase를 0.06rad 양자화(≈16스텝/회전)해
  // 같은 버킷이면 직전 Path를 재사용한다. 실기기에서 stroke/press 중 매 프레임
  // 일어나던 cubicTo 8회×Catmull-Rom 계산을 대부분 제거 → 프레임 비용 절감.
  // (캐시는 radius가 바뀌면도 무효화 — resize 시 _blobPath가 새로 그린다.)
  Path? _blobCache;
  double _blobCachePhase = -999;
  double _blobCacheRadius = -1;

  @override
  void paint(Canvas canvas, Size size) {
    // 물결 (누르기 GST-03) — 본체 변형과 독립이므로 월드 좌표에서 먼저.
    for (final r in ripples) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5 * r.life
        ..color = AppColors.jellyDeep.withValues(alpha: 0.4 * r.life);
      canvas.drawCircle(r.center, r.radius, paint);
    }

    final scale = ball.scale;
    final radius = ball.radius;
    // 누르기 깊이: v11 §A-4에서 복원 시 음수까지 오버슈트(통통 부풂)할 수 있어
    // [-0.3, 1.0]로 받는다. 양수=손가락에 눌려 납작(splat), 음수=반동으로 부풂.
    final pd = ball.pressDepth.clamp(-0.3, 1.0);
    final pressing = pd > 0.001; // 손가락이 닿아 있는(딤플/하이라이트 이동) 동안
    // pressDir = 누른 지점→중심 방향. 덴트는 그 반대(손가락 쪽)로 들어간다.
    final dent = pressing ? -ball.pressDir : Offset.zero;
    final pressAng = atan2(ball.pressDir.dy, ball.pressDir.dx);

    canvas.save();
    canvas.translate(ball.pos.dx, ball.pos.dy);

    // ── idle 호흡 + 쓰다듬기 swell(균일 확대) ──
    final swell = 1 + 0.05 * ball.strokeAmp.clamp(0.0, 1.0);
    canvas.scale(scale.dx * swell, scale.dy * swell);

    // ── 쓰다듬기 흐름 stretch+skew(§A-5: 액체가 쓸리는 결) ──
    // 공은 제자리(이동 없음)이되 표면만 손가락 속도 방향으로 늘어나고 비틀린다.
    // v12 §1: strokeFlow는 ball에서 강한 EMA로 부드럽게 누적되므로 여기 강도를 낮춰
    // "잔잔히 흐르게" 한다. 포화 기준을 ±34px로 넓히고(같은 흐름이 덜 격하게 차도록),
    // stretch +0.16→+0.10 / squash -0.07→-0.045 / skew ±0.14→±0.08로 약화 —
    // 튕김·날카로움 제거, 액체가 천천히 쓸리는 쫀득한 결.
    final flow = ball.strokeFlow;
    final fx = (flow.dx / 34).clamp(-1.0, 1.0);
    final fy = (flow.dy / 34).clamp(-1.0, 1.0);
    if (fx.abs() > 0.001 || fy.abs() > 0.001) {
      // 이동 축으로 늘고(최대 +0.10) 직교축은 살짝 눌림. skew는 ±0.08 rad.
      final mag = sqrt(fx * fx + fy * fy).clamp(0.0, 1.0);
      final stretchAlong = 1 + 0.10 * mag;
      final squashCross = 1 - 0.045 * mag;
      final ang = atan2(fy, fx);
      canvas.rotate(ang);
      canvas.scale(stretchAlong, squashCross);
      canvas.rotate(-ang);
      // 끈적 트레일링: 흐름 방향으로 표면을 비트는 전단(skew, 약화).
      canvas.transform(Float64List.fromList(<double>[
        1, fy * 0.08, 0, 0, //
        fx * 0.08, 1, 0, 0, //
        0, 0, 1, 0, //
        0, 0, 0, 1, //
      ]));
    }

    // ── 누르기 splat: 넓고 납작 + 손가락쪽 이동(§A-4) ──
    if (pd.abs() > 0.001) {
      // pressDir 축으로 회전 정렬 후 그 축(along)을 납작하게·직교축(cross)을 부풀려
      // "넓고 납작 철퍼덕". pd=1 → along 0.70 / cross 1.18(프로토타입 1.18/0.78 대응).
      // 음수 pd(반동)에서는 along>1, cross<1 → 평상보다 부푼 "통통" 오버슈트.
      final along = 1 - pd * 0.30;
      final cross = 1 + pd * 0.18;
      canvas.rotate(pressAng);
      canvas.scale(along, cross);
      canvas.rotate(-pressAng);
      // 손가락 쪽으로 본체 미세 이동(들어가는 방향감). 양수 깊이에서만.
      if (pressing) {
        canvas.translate(dent.dx * radius * 0.16 * pd, dent.dy * radius * 0.16 * pd);
      }
    }

    // 유기적 blob 경로(미세 모핑). 본체/음영/클립에 공유.
    final blob = _blobPath(radius, ball.morphPhase);

    // ── 쓰다듬기 글로우(본체 뒤 폭신한 발광) ──
    final e = strokeEnergy.clamp(0.0, 1.0);
    if (e > 0.01) {
      // 사용자 피드백: '주변이 은은하게 빛나면 좋겠다(아직 약함)' → 공 둘레로 크게
      // 번지는 아우라. 흰빛에 가깝게(파스텔 배경에서도 보이게), 알파를 e에 선형으로
      // 빠르게 올려(약하게 쓰다듬어도 곧 밝아짐), 반경·blur를 키운다.
      final glowColor = Color.lerp(AppColors.jellyDeep, Colors.white, 0.5)!;
      // (1) 넓고 옅게 번지는 바깥 아우라.
      final aura = Paint()
        ..color = glowColor.withValues(alpha: (0.22 + 0.30 * e).clamp(0.0, 0.55))
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 36 + 30 * e);
      canvas.drawCircle(Offset.zero, radius * (1.55 + 0.6 * e), aura);
      // (2) 본체 둘레에 더 또렷한 발광 링.
      final stroke = Paint()
        ..color = glowColor.withValues(alpha: (0.30 + 0.45 * e).clamp(0.0, 0.85))
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 24 + 20 * e);
      canvas.drawCircle(Offset.zero, radius * (1.26 + 0.34 * e), stroke);
    }

    // ── 외곽 drop 글로우 rgba(231,155,176,0.45) ──
    final outerGlow = Paint()
      ..color = _jelDropGlow.withValues(alpha: 0.45)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18);
    canvas.drawPath(blob.shift(const Offset(0, 6)), outerGlow); // 살짝 아래로(0 16px 느낌)

    // ── 본체 radial(white 0% → jellyCore 42% → jellyEdge 100%) ──
    // 하이라이트 중심 ≈ 36%/28%(좌상단). white는 jellyTint로 살짝 lerp해 과한
    // 흰 점을 피하되 거의 흰색을 유지.
    final body = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.28, -0.44), // 36%/28% 부근
        radius: 1.0,
        colors: [
          Color.lerp(AppColors.jellyHi, AppColors.jellyTint, 0.18)!, // 거의 흰
          AppColors.jellyCore, // #f4b8c7 핑크 본체
          AppColors.jellyEdge, // #e08aa6 외곽 끝색
        ],
        stops: const [0.0, 0.42, 1.0],
      ).createShader(Rect.fromCircle(center: Offset.zero, radius: radius));
    canvas.drawPath(blob, body);

    // ── 젤 inset 음영 + 구체 터미네이터(검정 금지) ──
    // v12 §2(성능): 직전엔 clipPath(blob) save/restore 블록을 두 번(inset용·shade용)
    // 잡아 매 프레임 클립을 2회 쌓았다 → 단일 클립 블록으로 합쳐 클립/저장 비용을 반감.
    // 또한 "우하단 어두운 inset"과 "구체 터미네이터 그늘"이 둘 다 우하단 짙은 핑크라
    // 거의 겹쳤으므로 inset 하나(우하단)로 통합해 radial 1장을 제거한다(룩 유지).
    canvas.save();
    canvas.clipPath(blob);
    // 통합 우하단 그늘: inset(193,96,128) 가장자리 + 터미네이터(coolShade)를 한 radial로.
    // 가장자리에서 안쪽으로 떨어지는 짙은 핑크 — inset 음영과 구체감을 동시에 낸다.
    final shadeCol = Color.lerp(_jelInsetDark,
        Color.lerp(AppColors.jellyCore, AppColors.jellyShade, 0.55)!, 0.35)!;
    final lowerShade = Paint()
      ..shader = RadialGradient(
        center: const Alignment(0.5, 0.6),
        radius: 1.12,
        colors: [
          shadeCol.withValues(alpha: 0.10),
          shadeCol.withValues(alpha: 0.18),
          shadeCol.withValues(alpha: 0.42),
        ],
        stops: const [0.0, 0.6, 1.0],
      ).createShader(Rect.fromCircle(center: Offset.zero, radius: radius * 1.1));
    canvas.drawCircle(Offset.zero, radius * 1.1, lowerShade);
    // 밝은 좌상단 inset (10 12 26 rgba(255,255,255,0.55)) — 흰 림 라이트.
    final insetLight = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.52, -0.6),
        radius: 1.05,
        colors: [
          Colors.white.withValues(alpha: 0.0),
          Colors.white.withValues(alpha: 0.0),
          Colors.white.withValues(alpha: 0.55),
        ],
        stops: const [0.0, 0.66, 1.0],
      ).createShader(Rect.fromCircle(center: Offset.zero, radius: radius * 1.05));
    canvas.drawCircle(Offset.zero, radius * 1.05, insetLight);
    canvas.restore();

    // ── 하이라이트(좌상단) — 누르기 중엔 덴트 쪽으로 끌려가 본체가 휘어 보이게 ──
    // v12 §2(성능): 직전엔 부드러운 하이라이트(blur4)와 또렷한 스펙큘러(blur1.5)를
    // 각각 maskFilter blur로 그렸다 → 부드러운 광택 하나만 blur로 두고, 또렷한
    // 스펙큘러는 blur 없는 작은 흰 점으로 겹쳐 표현(blur 레이어 1개 제거). 룩 유지.
    final hiBase = Offset(-radius * 0.32, -radius * 0.36);
    final hiPos = pressing ? hiBase + dent * (radius * 0.20 * pd) : hiBase;
    final hi = Paint()
      ..color = Colors.white.withValues(alpha: 0.5)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    canvas.drawCircle(hiPos, radius * 0.16, hi);

    // 작고 또렷한 스펙큘러 광택(top-left) — blur 없이(antialias만) 가벼운 흰 점.
    final specBase = Offset(-radius * 0.38, -radius * 0.42);
    final specPos = pressing ? specBase + dent * (radius * 0.20 * pd) : specBase;
    final spec = Paint()..color = Colors.white.withValues(alpha: 0.7);
    canvas.drawCircle(specPos, radius * 0.06, spec);

    // ── 누르기 손가락 자리 딤플 음영 rgba(150,70,95,0.45)→0, 0.42*지름 ──
    // 양수 깊이(실제 눌림)에서만. radial로 손가락 접점이 살짝 들어간 그늘.
    if (pressing) {
      final contact = dent * (radius * (0.42 + 0.12 * pd));
      final dimpleR = radius * 0.42; // 지름의 0.42 → 반경 기준
      final dimple = Paint()
        ..shader = RadialGradient(
          colors: [
            _dimpleShade.withValues(alpha: (0.45 * pd).clamp(0.0, 0.45)),
            _dimpleShade.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 1.0],
        ).createShader(Rect.fromCircle(center: contact, radius: dimpleR));
      canvas.drawCircle(contact, dimpleR, dimple);
    }

    // ── 쓰다듬기 위치 반응(손가락 닿는 자리 따라다니는 화이트 bloom) ──
    final sa = ball.strokeAmp.clamp(0.0, 1.0);
    if (sa > 0.01) {
      final bloom = Paint()
        ..color =
            Colors.white.withValues(alpha: (0.16 + 0.30 * sa).clamp(0.0, 0.50))
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 14 + 14 * sa);
      canvas.drawCircle(ball.strokeContact, radius * (0.30 + 0.10 * sa), bloom);
    }

    canvas.restore();
  }

  /// 완전 원이 아닌 유기적 blob 경로(중심 원점). [phase]로 ~6.5s 미세 모핑.
  ///
  /// 8방향 반경을 정현파로 ±약 6% 흔들어(프로토타입 border-radius 키프레임 근사)
  /// 닫힌 카드무-롬 스무딩 베지어로 잇는다. 과하지 않게(미세) — 슬라임 덩어리감.
  ///
  /// v12 §2(성능): phase를 0.06rad 버킷으로 양자화해 캐시한다. morphPhase가
  /// 0.967rad/s로 천천히 돌므로 같은 버킷(≈62ms)이면 직전 Path를 그대로 재사용 —
  /// 매 프레임 일어나던 8회 cubicTo 베지어 재계산을 대부분 제거한다. radius가
  /// 바뀌면(resize) 캐시를 무효화한다.
  Path _blobPath(double radius, double phase) {
    // phase 양자화(버킷). 같은 버킷·같은 radius면 캐시 재사용.
    final q = (phase / 0.06).floorToDouble() * 0.06;
    if (_blobCache != null &&
        _blobCacheRadius == radius &&
        (_blobCachePhase - q).abs() < 1e-9) {
      return _blobCache!;
    }
    const n = 8;
    final pts = <Offset>[];
    for (var i = 0; i < n; i++) {
      final a = i / n * 2 * pi;
      // 각 꼭짓점마다 다른 위상으로 흔들어 비대칭 일그러짐(완전 원 회피).
      final wob = 0.045 * sin(q + i * 1.7) + 0.025 * sin(q * 0.6 + i * 2.9);
      final rr = radius * (1 + wob);
      pts.add(Offset(cos(a) * rr, sin(a) * rr));
    }
    final path = _closedSmoothPath(pts);
    _blobCache = path;
    _blobCachePhase = q;
    _blobCacheRadius = radius;
    return path;
  }

  /// 점들을 카드무-롬→베지어로 부드럽게 잇는 닫힌 경로.
  Path _closedSmoothPath(List<Offset> pts) {
    final path = Path();
    final n = pts.length;
    if (n < 3) return path;
    path.moveTo(pts[0].dx, pts[0].dy);
    for (var i = 0; i < n; i++) {
      final p0 = pts[(i - 1 + n) % n];
      final p1 = pts[i];
      final p2 = pts[(i + 1) % n];
      final p3 = pts[(i + 2) % n];
      // Catmull-Rom → 베지어 제어점(텐션 1/6).
      final c1 = p1 + (p2 - p0) * (1 / 6);
      final c2 = p2 - (p3 - p1) * (1 / 6);
      path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
    }
    path.close();
    return path;
  }

  @override
  bool shouldRepaint(covariant EmotionBallPainter old) => false; // repaint로 갱신
}
