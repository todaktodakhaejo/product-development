import 'dart:math';

import 'package:flutter/material.dart';

// ─────────────────────────────────────────────────────────────────────────
// P3 로컬 색 상수 (theme 파일 수정 금지 → 여기 임시 보관).
// 정식 토큰화는 P1(app_theme.dart) 변경요청으로 승격할 것.
// ─────────────────────────────────────────────────────────────────────────
// TODO(P1-token): 재(ash) — 검게 식은 종이 조각.
const Color kAshGray = Color(0xFF4A4A52);
// TODO(P1-token): 연기(smoke) — 반투명 회색(알파 포함).
const Color kSmokeGray = Color(0x553A3A44);
// TODO(P1-token): 파쇄 폭죽 색종이 핑크.
const Color kConfettiPink = Color(0xFFFF8AB3);
// TODO(P1-token): 파쇄 폭죽 색종이 민트.
const Color kConfettiMint = Color(0xFF8FE3B0);
// TODO(P1-token): 보석함 sparkle 금빛.
const Color kSparkleGold = Color(0xFFFFE3A0);

/// 범용 파티클. 태우기 불씨/연기/재, 파쇄기 종이조각·폭죽·스트립, 보석함 sparkle에 공용.
class Particle {
  Particle({
    required this.pos,
    required this.vel,
    required this.color,
    required this.size,
    required this.life,
    this.gravity = 600,
    this.rotation = 0,
    this.spin = 0,
    this.shape = ParticleShape.circle,
    this.glow = false,
    this.sway = 0,
    this.grow = 0,
    this.aspect = 1.6,
  })  : _maxLife = life,
        _swaySeed = Random().nextDouble() * pi * 2;

  Offset pos;
  Offset vel;
  Color color;
  double size;
  double life; // 남은 수명(초)
  final double _maxLife;
  double gravity;
  double rotation;
  double spin;
  ParticleShape shape;

  /// 글로우 렌더 여부(불씨/폭죽/sparkle). painter가 MaskFilter.blur 레이어를 추가로 그림.
  final bool glow;

  /// 좌우 흔들림 진폭(px/s). 재·연기가 살랑이며 떨어지/오르도록.
  final double sway;

  /// 수명당 크기 증가율(연기처럼 퍼지는 입자). size += grow * dt.
  final double grow;

  /// rect/strip의 세로:가로 비율(strip은 길쭉하게).
  final double aspect;

  final double _swaySeed; // sway 위상 고정(결정적 흔들림)

  double get t => (life / _maxLife).clamp(0.0, 1.0); // 1 → 0
  double get age => (1.0 - t); // 0 → 1
  bool get dead => life <= 0;

  void update(double dt) {
    // 좌우 흔들림: 수명에 따라 진동하는 가로 속도 성분 추가.
    final swayDx =
        sway == 0 ? 0.0 : sin((_maxLife - life) * 3.2 + _swaySeed) * sway;
    vel = Offset(vel.dx + swayDx * dt, vel.dy + gravity * dt);
    pos += vel * dt;
    rotation += spin * dt;
    if (grow != 0) size += grow * dt;
    life -= dt;
  }
}

/// circle/rect는 기존. triangle=폭죽 다양화, ashFlake=재 조각, strip=파쇄 종이조각,
/// smoke=연기(큰 반투명 원), sparkle=보석함 반짝이(별 십자).
enum ParticleShape { circle, rect, triangle, ashFlake, strip, smoke, sparkle }

/// 파티클 묶음을 관리. emit* 헬퍼로 분출.
class ParticleField {
  ParticleField({this.maxParticles = 360});

  final List<Particle> particles = [];
  final Random _rng = Random();

  /// 입자 수 상한(저사양 폴백). 초과분은 가장 오래된 입자부터 제거.
  final int maxParticles;

  bool get isEmpty => particles.isEmpty;
  int get count => particles.length;

  void update(double dt) {
    for (final p in particles) {
      p.update(dt);
    }
    particles.removeWhere((p) => p.dead);
  }

  // 상한 가드: 추가 직전 호출. 넘치면 앞쪽(오래된) 입자 제거.
  void _cap() {
    final over = particles.length - maxParticles;
    if (over > 0) particles.removeRange(0, over);
  }

  // ── 기존 API (시그니처 보존) ──────────────────────────────────────────

  /// 폭죽/파쇄 분출: [origin]에서 사방으로.
  void emitBurst({
    required Offset origin,
    required int count,
    required List<Color> palette,
    double speed = 900,
    double sizeMin = 4,
    double sizeMax = 10,
    double life = 1.4,
    ParticleShape shape = ParticleShape.rect,
    double gravity = 700,
    double spread = pi * 2,
    double baseAngle = -pi / 2,
  }) {
    for (var i = 0; i < count; i++) {
      final angle = baseAngle + (_rng.nextDouble() - 0.5) * spread;
      final v = speed * (0.4 + _rng.nextDouble() * 0.6);
      particles.add(Particle(
        pos: origin,
        vel: Offset(cos(angle), sin(angle)) * v,
        color: palette[_rng.nextInt(palette.length)],
        size: sizeMin + _rng.nextDouble() * (sizeMax - sizeMin),
        life: life * (0.6 + _rng.nextDouble() * 0.6),
        gravity: gravity,
        rotation: _rng.nextDouble() * pi,
        spin: (_rng.nextDouble() - 0.5) * 12,
        shape: shape,
      ));
    }
    _cap();
  }

  /// 불씨/연기 지속 방출: [origin] 주변에서 위로 떠오름.
  void emitEmber({
    required Offset origin,
    required int count,
    required List<Color> palette,
  }) {
    for (var i = 0; i < count; i++) {
      final angle = -pi / 2 + (_rng.nextDouble() - 0.5) * 1.2;
      final v = 80 + _rng.nextDouble() * 140;
      particles.add(Particle(
        pos: origin + Offset((_rng.nextDouble() - 0.5) * 40, 0),
        vel: Offset(cos(angle), sin(angle)) * v,
        color: palette[_rng.nextInt(palette.length)],
        size: 3 + _rng.nextDouble() * 5,
        life: 0.8 + _rng.nextDouble() * 0.8,
        gravity: -120, // 위로 떠오름
        glow: true, // P3: 불씨 글로우
        shape: ParticleShape.circle,
      ));
    }
    _cap();
  }

  // ── P3 신규 API ──────────────────────────────────────────────────────

  /// 재(ash): 연소선에서 살짝 위로 떴다 중력으로 하강(좌우 살랑). 검게 식은 작은 조각.
  /// 태우기에서 emitEmber와 동시에 호출하면 상승(ember)+하강(ash) 입체감.
  void emitAsh({
    required Offset origin,
    int count = 2,
    List<Color> palette = const [kAshGray],
  }) {
    for (var i = 0; i < count; i++) {
      final angle = -pi / 2 + (_rng.nextDouble() - 0.5) * 1.6;
      final v = 30 + _rng.nextDouble() * 60; // 약하게 떠오른 뒤 곧 하강
      particles.add(Particle(
        pos: origin + Offset((_rng.nextDouble() - 0.5) * 60, 0),
        vel: Offset(cos(angle), sin(angle)) * v,
        color: palette[_rng.nextInt(palette.length)],
        size: 2 + _rng.nextDouble() * 4,
        life: 1.6 + _rng.nextDouble() * 1.2,
        gravity: 90, // 양수 → 하강
        sway: 26 + _rng.nextDouble() * 24, // 좌우 흔들림
        rotation: _rng.nextDouble() * pi,
        spin: (_rng.nextDouble() - 0.5) * 4,
        shape: ParticleShape.ashFlake,
      ));
    }
    _cap();
  }

  /// 흰 재 스노폴(emitSnowAsh): 연소선에서 떠오른 하얀 재가 **눈처럼** 천천히
  /// 살랑이며 내려온다. emitAsh(검은 kAshGray)와 달리 ① gravity 28~40(아주 느린
  /// 하강) ② sway 40~70(크게 살랑) ③ life 3.0~4.5(오래 떠 있음) ④ 흰 팔레트로
  /// "정화된 눈" 무드를 만든다. shape는 ashFlake 재사용.
  ///
  /// [width]>0이면 origin 좌우로 width만큼 가로 분산(연소선 전폭 살포).
  /// emitAsh 시그니처는 그대로 보존(다른 호출처 회귀 0) — 흰 재는 이 전용 메서드로.
  void emitSnowAsh({
    required Offset origin,
    int count = 2,
    double width = 0,
    // TODO(P1-token): 흰 재 스노폴 팔레트(따뜻·정화 톤). app_theme 승격 대상.
    List<Color> palette = const [
      Color(0xFFF5F5F7),
      Color(0xFFFFFFFF),
      Color(0xFFE8E8EC),
    ],
  }) {
    for (var i = 0; i < count; i++) {
      // 가로 분산: width>0이면 전폭, 아니면 origin 주변 좁게.
      final dx = width > 0
          ? (_rng.nextDouble() - 0.5) * width
          : (_rng.nextDouble() - 0.5) * 40;
      // 살짝 위로 떴다 곧 느린 중력으로 하강(연소선에서 피어오르는 느낌).
      final angle = -pi / 2 + (_rng.nextDouble() - 0.5) * 1.8;
      final v = 16 + _rng.nextDouble() * 30;
      particles.add(Particle(
        pos: origin + Offset(dx, 0),
        vel: Offset(cos(angle), sin(angle)) * v,
        color: palette[_rng.nextInt(palette.length)],
        size: 2.5 + _rng.nextDouble() * 2.5, // 2.5~5
        life: 3.0 + _rng.nextDouble() * 1.5, // 3.0~4.5: 오래 떠 있음
        gravity: 28 + _rng.nextDouble() * 12, // 28~40: 눈처럼 아주 느린 하강
        sway: 40 + _rng.nextDouble() * 30, // 40~70: 크게 살랑
        rotation: _rng.nextDouble() * pi,
        spin: (_rng.nextDouble() - 0.5) * 2.4, // 천천히 회전
        shape: ParticleShape.ashFlake,
      ));
    }
    _cap();
  }

  /// 연기(smoke): 연소 경계 위로 천천히 떠오르며 커지고 옅어지는 큰 회색 원.
  void emitSmoke({
    required Offset origin,
    int count = 1,
    Color color = kSmokeGray,
  }) {
    for (var i = 0; i < count; i++) {
      final angle = -pi / 2 + (_rng.nextDouble() - 0.5) * 0.5;
      final v = 18 + _rng.nextDouble() * 22;
      particles.add(Particle(
        pos: origin + Offset((_rng.nextDouble() - 0.5) * 28, 0),
        vel: Offset(cos(angle), sin(angle)) * v,
        color: color,
        size: 14 + _rng.nextDouble() * 12,
        life: 2.4 + _rng.nextDouble() * 1.6,
        gravity: -26, // 천천히 상승
        sway: 14 + _rng.nextDouble() * 12,
        grow: 22 + _rng.nextDouble() * 18, // 퍼짐
        shape: ParticleShape.smoke,
      ));
    }
    _cap();
  }

  /// 파쇄 스트립: 슬릿 [origin]에서 짧은 종이 strip이 잘려 회전 낙하.
  /// [width]는 슬릿(투입구) 가로폭 — strip이 그 안에서 가로 분산되어 떨어짐.
  void emitStrip({
    required Offset origin,
    required double width,
    int count = 2,
    List<Color> palette = const [Color(0xFFF6F1E7)], // 기본 = AppColors.paper 근사
  }) {
    for (var i = 0; i < count; i++) {
      final dx = (_rng.nextDouble() - 0.5) * width;
      particles.add(Particle(
        pos: origin + Offset(dx, 0),
        vel: Offset((_rng.nextDouble() - 0.5) * 60, 40 + _rng.nextDouble() * 80),
        color: palette[_rng.nextInt(palette.length)],
        size: 4 + _rng.nextDouble() * 3, // 가로폭(strip)
        life: 1.4 + _rng.nextDouble() * 0.8,
        gravity: 900,
        rotation: (_rng.nextDouble() - 0.5) * 0.6,
        spin: (_rng.nextDouble() - 0.5) * 6,
        aspect: 5 + _rng.nextDouble() * 4, // 길쭉
        shape: ParticleShape.strip,
      ));
    }
    _cap();
  }

  /// 2단 폭죽: emitBurst(1차) 직후 호출하면 잔입자 반짝이(작은 sparkle) 2차.
  /// emitBurst를 먼저 쏘고, 2차는 화면에서 Future로 지연 호출 권장(notes 참고).
  void emitBurstSparkle({
    required Offset origin,
    int count = 40,
    List<Color> palette = const [kSparkleGold, kConfettiPink, kConfettiMint],
    double speed = 420,
  }) {
    for (var i = 0; i < count; i++) {
      final angle = _rng.nextDouble() * pi * 2;
      final v = speed * (0.3 + _rng.nextDouble() * 0.7);
      particles.add(Particle(
        pos: origin,
        vel: Offset(cos(angle), sin(angle)) * v,
        color: palette[_rng.nextInt(palette.length)],
        size: 2 + _rng.nextDouble() * 3,
        life: 0.7 + _rng.nextDouble() * 0.6,
        gravity: 120,
        glow: true,
        shape: ParticleShape.sparkle,
      ));
    }
    _cap();
  }

  /// 보석함 sparkle: 안치 순간 [origin] 둘레에서 위로 살짝 떠오르는 짧은 금빛 반짝이.
  void emitSparkle({
    required Offset origin,
    int count = 18,
    double radius = 60,
    List<Color> palette = const [kSparkleGold],
  }) {
    for (var i = 0; i < count; i++) {
      final a = _rng.nextDouble() * pi * 2;
      final r = _rng.nextDouble() * radius;
      final p = origin + Offset(cos(a) * r, sin(a) * r * 0.6);
      particles.add(Particle(
        pos: p,
        vel:
            Offset((_rng.nextDouble() - 0.5) * 30, -20 - _rng.nextDouble() * 30),
        color: palette[_rng.nextInt(palette.length)],
        size: 2 + _rng.nextDouble() * 3,
        life: 0.8 + _rng.nextDouble() * 0.7,
        gravity: -8, // 거의 떠 있다 사라짐
        glow: true,
        shape: ParticleShape.sparkle,
      ));
    }
    _cap();
  }
}

class ParticlePainter extends CustomPainter {
  ParticlePainter(this.field, Listenable repaint) : super(repaint: repaint);
  final ParticleField field;

  // 글로우용 blur 필터(상수 재사용 — 매 입자 새로 만들지 않음).
  static const MaskFilter _glowFilter = MaskFilter.blur(BlurStyle.normal, 6);
  static const MaskFilter _smokeFilter = MaskFilter.blur(BlurStyle.normal, 10);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (final p in field.particles) {
      final alpha = p.t.clamp(0.0, 1.0); // 수명 종료 직전 0으로 페이드
      paint
        ..color = p.color.withValues(alpha: p.color.a * alpha)
        ..maskFilter = null;

      switch (p.shape) {
        case ParticleShape.circle:
          if (p.glow) _drawGlow(canvas, p, alpha);
          paint.color = p.color.withValues(alpha: alpha);
          canvas.drawCircle(p.pos, p.size * (0.4 + p.t * 0.6), paint);

        case ParticleShape.rect:
          paint.color = p.color.withValues(alpha: alpha);
          _drawRotatedRect(canvas, p, paint, p.size, p.size * p.aspect);

        case ParticleShape.strip:
          // 길쭉한 종이 조각(세로로 긴 rect).
          paint.color = p.color.withValues(alpha: alpha);
          _drawRotatedRect(canvas, p, paint, p.size, p.size * p.aspect);

        case ParticleShape.triangle:
          if (p.glow) _drawGlow(canvas, p, alpha);
          paint.color = p.color.withValues(alpha: alpha);
          _drawTriangle(canvas, p, paint);

        case ParticleShape.ashFlake:
          // 작은 검은 사각 조각 — 회전하며 떨어짐.
          paint.color = p.color.withValues(alpha: p.color.a * alpha);
          _drawRotatedRect(canvas, p, paint, p.size, p.size * 1.2);

        case ParticleShape.smoke:
          // 큰 반투명 원 + blur. age에 따라 더 옅게.
          paint
            ..maskFilter = _smokeFilter
            ..color = p.color.withValues(alpha: p.color.a * alpha * 0.8);
          canvas.drawCircle(p.pos, p.size, paint);
          paint.maskFilter = null;

        case ParticleShape.sparkle:
          if (p.glow) _drawGlow(canvas, p, alpha);
          paint.color = p.color.withValues(alpha: alpha);
          _drawSparkle(canvas, p, paint);
      }
    }
  }

  // 부드러운 글로우: 입자 위치에 큰 blur 원을 가산적으로 깔아준다.
  void _drawGlow(Canvas canvas, Particle p, double alpha) {
    final glow = Paint()
      ..maskFilter = _glowFilter
      ..color = p.color.withValues(alpha: alpha * 0.5);
    canvas.drawCircle(p.pos, p.size * (1.4 + p.t * 0.8), glow);
  }

  void _drawRotatedRect(
      Canvas canvas, Particle p, Paint paint, double w, double h) {
    canvas.save();
    canvas.translate(p.pos.dx, p.pos.dy);
    canvas.rotate(p.rotation);
    canvas.drawRect(
      Rect.fromCenter(center: Offset.zero, width: w, height: h),
      paint,
    );
    canvas.restore();
  }

  void _drawTriangle(Canvas canvas, Particle p, Paint paint) {
    canvas.save();
    canvas.translate(p.pos.dx, p.pos.dy);
    canvas.rotate(p.rotation);
    final s = p.size;
    final path = Path()
      ..moveTo(0, -s)
      ..lineTo(s * 0.87, s * 0.5)
      ..lineTo(-s * 0.87, s * 0.5)
      ..close();
    canvas.drawPath(path, paint);
    canvas.restore();
  }

  // 반짝임: 작은 십자(4방향) — 별처럼 보이게.
  void _drawSparkle(Canvas canvas, Particle p, Paint paint) {
    final s = p.size * (0.6 + p.t * 0.8);
    canvas.save();
    canvas.translate(p.pos.dx, p.pos.dy);
    canvas.rotate(p.rotation);
    final path = Path()
      ..moveTo(0, -s * 1.8)
      ..lineTo(s * 0.4, 0)
      ..lineTo(0, s * 1.8)
      ..lineTo(-s * 0.4, 0)
      ..close()
      ..moveTo(-s * 1.8, 0)
      ..lineTo(0, s * 0.4)
      ..lineTo(s * 1.8, 0)
      ..lineTo(0, -s * 0.4)
      ..close();
    canvas.drawPath(path, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant ParticlePainter old) => false;
}
