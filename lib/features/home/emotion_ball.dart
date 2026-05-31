import 'dart:math';
import 'dart:ui';

/// 누르기(GST-03) 시 퍼지는 물결.
class Ripple {
  Ripple(this.center) : life = 1.0;
  final Offset center;
  double life; // 1 → 0
  double get radius => (1 - life) * maxRadius;
  static const double maxRadius = 160;

  void update(double dt) => life = (life - dt * 1.6).clamp(0.0, 1.0);
  bool get dead => life <= 0;
}

/// 감정 오브제(공)의 물리 + 변형 상태.
///
/// - 기울기 중력(굴리기, GST-02)과 흔들기 임펄스(GST-01)를 받아 움직이고,
///   벽에 부딪히면 [lastImpact]에 충돌 세기를 남겨 햅틱을 트리거한다.
/// - 손으로 잡으면([grab]) 손가락을 따라오며 젤리처럼 출렁인다(GST-04).
class EmotionBall {
  EmotionBall({required this.bounds})
      : pos = bounds.center,
        radius = _radiusFor(bounds);

  Rect bounds;
  Offset pos;
  Offset vel = Offset.zero;
  double radius;

  // 젤리 변형: squash(눌림 정도) + 방향, wobble(잔진동 위상)
  double squash = 0; // 0~1
  Offset squashDir = const Offset(0, 1);
  double _wobblePhase = 0;
  double wobbleAmp = 0;

  bool grabbed = false;

  /// 직전 프레임의 벽 충돌 세기(0~1). 0이면 충돌 없음. 읽고 나면 소비.
  double lastImpact = 0;
  Offset lastImpactDir = Offset.zero;

  static double _radiusFor(Rect b) => (b.shortestSide * 0.16).clamp(48.0, 110.0);

  void resize(Rect b) {
    bounds = b;
    radius = _radiusFor(b);
    pos = Offset(
      pos.dx.clamp(b.left + radius, b.right - radius),
      pos.dy.clamp(b.top + radius, b.bottom - radius),
    );
  }

  /// 흔들기/던지기 임펄스 추가. [strength]는 0~1.
  void addImpulse(Offset dir, double strength) {
    vel += dir * (strength * 1400);
    _bumpWobble(strength);
  }

  void _bumpWobble(double s) {
    wobbleAmp = min(1.0, wobbleAmp + s * 0.6);
  }

  /// 손으로 잡아 끌기(문지르기). [target]은 손가락 위치.
  void grab(Offset target) {
    grabbed = true;
    final clamped = Offset(
      target.dx.clamp(bounds.left + radius, bounds.right - radius),
      target.dy.clamp(bounds.top + radius, bounds.bottom - radius),
    );
    final delta = clamped - pos;
    vel = delta * 12; // 손가락 추종 속도 → 출렁임 유발
    // 변형은 끄는 반대 방향으로
    final d = delta.distance;
    if (d > 0.001) {
      squash = min(0.5, d / radius);
      squashDir = delta / d;
    }
    _bumpWobble(min(0.4, d / radius));
    pos = clamped;
  }

  void release() {
    grabbed = false;
  }

  /// 한 프레임 물리 적분.
  /// [gravity]는 기기 기울기에서 온 가속도(이미 스케일됨).
  void update(double dt, Offset gravity) {
    lastImpact = 0;
    _wobblePhase += dt * 18;
    wobbleAmp = (wobbleAmp - dt * 1.4).clamp(0.0, 1.0);
    squash = (squash - dt * 3.0).clamp(0.0, 1.0);

    if (grabbed) return; // 잡고 있는 동안 물리 정지(grab에서 직접 위치 갱신)

    // 중력(기울기) 적용
    vel += gravity * dt;
    // 공기 저항/마찰
    vel *= (1 - 0.9 * dt);
    pos += vel * dt;

    _collideWalls();
  }

  void _collideWalls() {
    const restitution = 0.62;
    double impact = 0;
    Offset dir = Offset.zero;

    if (pos.dx < bounds.left + radius) {
      pos = Offset(bounds.left + radius, pos.dy);
      if (vel.dx < 0) {
        impact = max(impact, vel.dx.abs());
        dir = const Offset(1, 0);
        vel = Offset(-vel.dx * restitution, vel.dy);
      }
    } else if (pos.dx > bounds.right - radius) {
      pos = Offset(bounds.right - radius, pos.dy);
      if (vel.dx > 0) {
        impact = max(impact, vel.dx.abs());
        dir = const Offset(-1, 0);
        vel = Offset(-vel.dx * restitution, vel.dy);
      }
    }

    if (pos.dy < bounds.top + radius) {
      pos = Offset(pos.dx, bounds.top + radius);
      if (vel.dy < 0) {
        impact = max(impact, vel.dy.abs());
        dir = const Offset(0, 1);
        vel = Offset(vel.dx, -vel.dy * restitution);
      }
    } else if (pos.dy > bounds.bottom - radius) {
      pos = Offset(pos.dx, bounds.bottom - radius);
      if (vel.dy > 0) {
        impact = max(impact, vel.dy.abs());
        dir = const Offset(0, -1);
        vel = Offset(vel.dx, -vel.dy * restitution);
      }
    }

    if (impact > 60) {
      // 충돌 세기를 0~1로 정규화 + 충돌 방향으로 squash
      lastImpact = (impact / 2200).clamp(0.0, 1.0);
      lastImpactDir = dir;
      squash = max(squash, lastImpact * 0.6);
      squashDir = dir;
      _bumpWobble(lastImpact);
    }
  }

  bool hitTest(Offset p) => (p - pos).distance <= radius * 1.25;

  /// 현재 변형을 반영한 (scaleX, scaleY).
  Offset get scale {
    final w = sin(_wobblePhase) * wobbleAmp * 0.12;
    // squashDir 축으로 눌리고 직교축으로 늘어남
    final along = 1 - squash * 0.5 + w;
    final cross = 1 + squash * 0.4 - w;
    final horizontal = squashDir.dx.abs() > squashDir.dy.abs();
    return horizontal ? Offset(along, cross) : Offset(cross, along);
  }
}
