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
/// - 흔들기 임펄스([addImpulse])를 받아 움직이고, 벽에 부딪히면
///   [lastImpact]에 충돌 세기를 남겨 햅틱을 트리거한다.
/// - 손으로 끌면([grab]) 손가락을 따라와 굴러가고(GST-02), 놓으면 관성으로 fling 한다.
/// - 제자리 쓰다듬으면([stroke]) 원위치 근처에서 표면만 출렁인다(GST-04).
/// - [update]의 [gravity] 인자는 타 화면(의식 등) 재사용성을 위해 유지하되,
///   홈 화면에서는 `Offset.zero`를 전달한다.
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

  // ── 누르기 푸딩감(GST-03) 상태 ──────────────────────────────
  // 본체가 탭 지점 방향으로 쑤욱 침몰(squash 덴트)했다가 elastic으로 차오른다.
  // 시간 진행은 [update]에서 관리하며, painter는 [pressDepth]/[pressDir]를 읽기만 한다.
  double _pressT = -1; // 진행 시간(s). <0이면 비활성
  Offset _pressDir = Offset.zero; // 탭 지점 → 중심 방향(덴트 축)
  bool _pressReleased = false; // 복원 정점 도달 플래그(consume으로 1회 소비)
  bool _pressPeakArmed = false; // 침몰 정점을 지나 복원 구간 진입 여부

  // 침몰 ~90ms, 복원 ~520ms elastic. (§11-5 motion 재량 튜닝)
  static const double _pressInDur = 0.09;
  static const double _pressOutDur = 0.52;

  static double _radiusFor(Rect b) => (b.shortestSide * 0.22).clamp(64.0, 150.0);

  void resize(Rect b) {
    bounds = b;
    radius = _radiusFor(b);
    pos = Offset(
      pos.dx.clamp(b.left + radius, b.right - radius),
      pos.dy.clamp(b.top + radius, b.bottom - radius),
    );
  }

  /// 흔들기/던지기 임펄스 추가. [strength]는 0~1.
  ///
  /// 기준 속도 1700(§6.1): 약 구간에서도 체감되도록 상향. 안정화(§7)의
  /// 2단 마찰·정지 임계가 빠르게 잡아주므로 무한 잔진동 없이 "처음 활발→곧 정지".
  void addImpulse(Offset dir, double strength) {
    vel += dir * (strength * 1700);
    _bumpWobble(strength);
  }

  /// 누르기(GST-03): 탭 지점 방향으로 본체를 침몰시킨다.
  ///
  /// [localPos]는 탭한 화면 좌표. 침몰 축([pressDir])은 "탭 지점 → 중심" 방향이며,
  /// 시간 진행은 [update]가 처리한다(침몰 ~90ms → 복원 ~520ms elastic).
  /// painter는 [pressDepth]/[pressDir]만 읽어 본체 변형으로 표현한다.
  void press(Offset localPos) {
    final toCenter = pos - localPos;
    final d = toCenter.distance;
    // 정중앙 탭이면 위에서 누른 듯 아래로 살짝 들어가게(영벡터 회피).
    _pressDir = d > 0.001 ? toCenter / d : const Offset(0, -1);
    _pressT = 0;
    _pressReleased = false;
    _pressPeakArmed = false;
  }

  /// painter가 읽는 현재 침몰 깊이(0~1). 0=평소, peak=최대 침몰.
  double get pressDepth {
    if (_pressT < 0) return 0;
    if (_pressT < _pressInDur) {
      // 침몰: 빠르게 들어감(가속). 0→1
      final t = (_pressT / _pressInDur).clamp(0.0, 1.0);
      return t * t * (3 - 2 * t); // smoothstep
    }
    // 복원: elasticOut으로 천천히 차오르며 살짝 오버슈트. 1→0
    final t = ((_pressT - _pressInDur) / _pressOutDur).clamp(0.0, 1.0);
    return (1 - _elasticOut(t)).clamp(0.0, 1.0);
  }

  /// 덴트 축(탭 지점 → 중심 정규화). painter 본체 변형 방향.
  Offset get pressDir => _pressDir;

  /// 복원 정점 도달 프레임에 true를 1회 반환하고 소비(이후 false).
  ///
  /// home_screen `_onTick`이 읽어 `pressRelease()` 햅틱을 발사한다 — 물리 타이밍과
  /// 한 소스에서 동기되어 desync를 방지한다(§6.3-B).
  bool consumePressRelease() {
    if (_pressReleased) {
      _pressReleased = false;
      return true;
    }
    return false;
  }

  /// elasticOut 근사(Flutter Curves.elasticOut와 동형, period 0.4).
  static double _elasticOut(double t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    const period = 0.4;
    const s = period / 4;
    return pow(2, -10 * t).toDouble() *
            sin((t - s) * (2 * pi) / period) +
        1;
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

  /// 제자리 쓰다듬기(GST-04). [step]은 직전 프레임 대비 손가락 이동량.
  ///
  /// 공은 크게 옮기지 않고 현 위치 근처에서 약하게만 따라가며(잔잔한 추종),
  /// 표면 출렁임([wobbleAmp])과 약한 squash만 키운다. fling용 [vel]은 부여하지 않는다.
  void stroke(Offset step) {
    grabbed = true; // update의 물리 적분을 멈춰 제자리 유지
    final len = step.distance;
    if (len > 0.001) {
      // 손가락 방향으로 아주 약하게만 끌려옴(원위치 이탈 최소화)
      pos += step * 0.06;
      pos = Offset(
        pos.dx.clamp(bounds.left + radius, bounds.right - radius),
        pos.dy.clamp(bounds.top + radius, bounds.bottom - radius),
      );
      // 쓸리는 방향으로 약한 squash (dreamy: 천천히 차오르도록 계수 낮춤).
      // 누르기 덴트와 달리 얕게 유지(상한 0.18) — §5 차별화 표.
      squash = min(0.18, squash + len / radius * 0.35);
      squashDir = step / len;
    }
    vel = Offset.zero; // fling 금지
    // 매 move마다 살짝씩만 더해 부드럽게 출렁이게(스파이크 방지) — update의
    // wobbleAmp 감쇠(-dt*1.4)와 맞물려 멈추면 자연 감쇠한다.
    // v2: 잔잔히 더 번지도록 출렁임 계수·상한을 소폭 상향(요구2, 위로받는 텍스처).
    _bumpWobble(min(0.30, len / radius * 0.75));
  }

  /// 한 프레임 물리 적분.
  /// [gravity]는 외부에서 주는 가속도(이미 스케일됨). 홈 화면은 `Offset.zero` 전달.
  void update(double dt, Offset gravity) {
    lastImpact = 0;
    _wobblePhase += dt * 18;
    wobbleAmp = (wobbleAmp - dt * 1.4).clamp(0.0, 1.0);
    squash = (squash - dt * 3.0).clamp(0.0, 1.0);

    // ── 누르기 침몰/복원 시간 진행(§6.3) ──
    // grabbed 여부와 무관하게 진행(쓰다듬기 중 탭은 없지만 안전하게 항상 갱신).
    if (_pressT >= 0) {
      _pressT += dt;
      // 침몰 정점(_pressInDur)을 지나면 복원 구간 진입을 무장.
      if (!_pressPeakArmed && _pressT >= _pressInDur) {
        _pressPeakArmed = true;
      }
      // 복원 완료 정점에 도달하면 햅틱 플래그를 1회 올리고 상태 종료.
      if (_pressPeakArmed && _pressT >= _pressInDur + _pressOutDur) {
        _pressReleased = true; // consumePressRelease()가 1회 소비
        _pressT = -1;
        _pressPeakArmed = false;
      }
    }

    if (grabbed) return; // 잡고 있는 동안 물리 정지(grab에서 직접 위치 갱신)

    // 중력(기울기) 적용
    vel += gravity * dt;

    // ── 2단 마찰(§7): 빠르면 활발히 튀게 약감속, 느리면 빠르게 잦아듦 ──
    final speed = vel.distance;
    final friction = speed > _kFastSpeed ? 1.0 : 3.2;
    vel *= (1 - friction * dt);

    pos += vel * dt;

    final collided = _collideWalls();

    // ── 정지 임계(snap-to-stop, §7): 저속이면 vel=0으로 떨림 종결 ──
    // 벽 충돌 직후 프레임은 제외(튕김 속도를 죽이지 않도록).
    if (!collided && vel.distance < _kStopSpeed) {
      vel = Offset.zero;
    }
  }

  // 안정화 튜닝 상수(§7·§11-4, 실기기 체감 조정 대상)
  static const double _kFastSpeed = 900; // px/s 초과 시 약감속
  static const double _kStopSpeed = 26; // px/s 미만 시 snap-to-stop

  /// 벽 충돌 처리. 이번 프레임에 실제 반발(튕김)이 일어났으면 true.
  /// (정지 임계가 튕김 직후 속도를 죽이지 않도록 호출부가 참고.)
  bool _collideWalls() {
    const restitution = 0.5; // v2: 0.62→0.5, 튕김 횟수↓·빠른 정착(탱탱함 유지)
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
      return true;
    }
    return false;
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
