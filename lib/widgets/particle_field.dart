import 'dart:math';

import 'package:flutter/material.dart';

/// 글자가 흩어져 사라지는 의식(분출)의 입자 하나.
class Particle {
  Particle({
    required this.origin,
    required this.direction,
    required this.speed,
    required this.radius,
    required this.delay,
  });

  /// 시작 위치(0~1로 정규화, 필드 기준).
  final Offset origin;

  /// 이동 방향(라디안). 대체로 위쪽(-pi/2).
  final double direction;

  /// progress 1일 때 이동 거리(필드 높이 비율).
  final double speed;
  final double radius;

  /// 시작 지연(0~0.35). 한꺼번에 터지지 않고 번지듯 흩어지게.
  final double delay;

  static List<Particle> generate(int count, {required int seed}) {
    final rnd = Random(seed);
    return List.generate(count, (_) {
      final ox = 0.5 + (rnd.nextDouble() - 0.5) * 0.72;
      final oy = 0.5 + (rnd.nextDouble() - 0.5) * 0.30;
      final direction = -pi / 2 + (rnd.nextDouble() - 0.5) * (pi * 0.7);
      final speed = 0.28 + rnd.nextDouble() * 0.62;
      final radius = 1.2 + rnd.nextDouble() * 3.2;
      final delay = rnd.nextDouble() * 0.35;
      return Particle(
        origin: Offset(ox, oy),
        direction: direction,
        speed: speed,
        radius: radius,
        delay: delay,
      );
    });
  }
}

/// progress 0~1 동안 입자들이 위로 흩어지며 사라지는 모습을 그린다.
class ParticlePainter extends CustomPainter {
  ParticlePainter({
    required this.progress,
    required this.color,
    required this.particles,
  });

  final double progress;
  final Color color;
  final List<Particle> particles;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    for (final p in particles) {
      final span = 1 - p.delay;
      final local = ((progress - p.delay) / span).clamp(0.0, 1.0);
      if (local <= 0) continue;

      final eased = Curves.easeOut.transform(local);
      final distance = p.speed * eased * size.height;
      final dx = p.origin.dx * size.width + cos(p.direction) * distance;
      final dy = p.origin.dy * size.height + sin(p.direction) * distance;

      final alpha = (1 - local) * 0.9;
      final paint = Paint()
        ..color = color.withValues(alpha: alpha)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.6);
      canvas.drawCircle(Offset(dx, dy), p.radius * (1 - local * 0.5), paint);
    }
  }

  @override
  bool shouldRepaint(ParticlePainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}
