import 'dart:math';

import 'package:flutter/material.dart';

/// 범용 파티클. 태우기 불씨/연기, 파쇄기 종이조각·폭죽에 공용.
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
  }) : _maxLife = life;

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

  double get t => (life / _maxLife).clamp(0.0, 1.0); // 1 → 0
  bool get dead => life <= 0;

  void update(double dt) {
    vel = Offset(vel.dx, vel.dy + gravity * dt);
    pos += vel * dt;
    rotation += spin * dt;
    life -= dt;
  }
}

enum ParticleShape { circle, rect }

/// 파티클 묶음을 관리. [emitBurst]로 한 번에 분출.
class ParticleField {
  final List<Particle> particles = [];
  final Random _rng = Random();

  bool get isEmpty => particles.isEmpty;

  void update(double dt) {
    for (final p in particles) {
      p.update(dt);
    }
    particles.removeWhere((p) => p.dead);
  }

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
        shape: ParticleShape.circle,
      ));
    }
  }
}

class ParticlePainter extends CustomPainter {
  ParticlePainter(this.field, Listenable repaint) : super(repaint: repaint);
  final ParticleField field;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (final p in field.particles) {
      paint.color = p.color.withValues(alpha: p.t);
      switch (p.shape) {
        case ParticleShape.circle:
          canvas.drawCircle(p.pos, p.size * (0.4 + p.t * 0.6), paint);
        case ParticleShape.rect:
          canvas.save();
          canvas.translate(p.pos.dx, p.pos.dy);
          canvas.rotate(p.rotation);
          canvas.drawRect(
            Rect.fromCenter(
                center: Offset.zero, width: p.size, height: p.size * 1.6),
            paint,
          );
          canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(covariant ParticlePainter old) => false;
}
