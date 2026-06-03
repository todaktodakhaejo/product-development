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
/// - 본체 위를 누르고 있으면([pressStart]) 누른 시간만큼 점점 깊이 침몰하고,
///   떼면([pressEnd]) elastic으로 차오른다(GST-03 홀드, v3 §2).
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

  // ── 쓰다듬기 위치 반응(GST-04, v8 §1-B) 상태 ──────────────────
  // 손가락이 닿는 자리를 중심 기준 로컬좌표로 들고 있다가(painter가 그 위치에
  // 화이트 bloom 광택을 그림), stroke가 멈추면 시간 감쇠(~1.2s)로 잦아든다.
  // 공 자체는 전혀 움직이지 않으므로(완전 제자리) pos/vel과는 독립적인 표면 반응.
  Offset _strokeContact = Offset.zero; // 중심 기준 로컬좌표(radius*0.85로 clamp)
  double _strokeAmp = 0; // 0~1, stroke 중 상승·시간 감쇠

  /// painter가 읽는 쓰다듬기 접촉 위치(중심 기준 로컬좌표). 표면 광택 중심.
  Offset get strokeContact => _strokeContact;

  /// painter가 읽는 쓰다듬기 접촉 세기(0~1). 광택 알파/반경에 사용.
  double get strokeAmp => _strokeAmp;

  /// 직전 프레임의 벽 충돌 세기(0~1). 0이면 충돌 없음. 읽고 나면 소비.
  double lastImpact = 0;
  Offset lastImpactDir = Offset.zero;

  // ── 누르기 홀드(GST-03, v3 §2) 상태 ──────────────────────────
  // 본체 위에서 손가락을 누르고 있는 동안 깊이가 시간 비례로 차오르고(상한 1.0),
  // 떼면 현재 깊이에서 elastic으로 0까지 복원한다. 시간 진행은 [update]가 관리하며,
  // painter는 [pressDepth]/[pressDir]만 읽는다.
  bool _holding = false; // 손가락이 본체를 누르고 있는 중
  double _holdT = 0; // 홀드 누적 시간(s) — 침몰 깊이 계산용
  double _releaseDepth = 0; // 뗀 순간의 깊이(elastic 복원 시작점)
  double _releaseT = -1; // 복원 진행 시간(s). <0이면 복원 비활성
  double _curDepth = 0; // 현재 깊이(0~1) — pressDepth가 그대로 반환
  Offset _pressDir = Offset.zero; // 탭 지점 → 중심 방향(덴트 축)
  // v9 §2-B: 손가락이 닿은 접촉점(중심 기준 로컬좌표, radius*0.7로 clamp).
  // painter가 그 자리에 "뽁" 국소 오목 덴트를 그린다. pressDepth=0이면 painter가
  // 무시하므로 복원/취소 종료 시 별도 리셋 불필요(접촉점은 깊이가 게이트).
  Offset _pressContact = Offset.zero;

  // 미세 틱(pressHoldTick) — 침몰 중 0.5·0.85 통과 정점에서 1회씩.
  bool _tick50Armed = false;
  bool _tick85Armed = false;
  bool _tickPending = false;

  // 침몰 0.45s(ease-out), 복원 0.5s elasticOut. (v3 §2)
  static const double _holdInDur = 0.45;
  static const double _releaseDur = 0.5;

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
  /// 기준 속도 5000(v8 §3: 4200→5000으로 상한 확대 — 세기 대비 4배). builder가
  /// 흔든 방향·세기를 0.25~1.0로 넓게 매핑하므로, 살살 흔들면 0.25*5000=1250px/s로
  /// 살짝만 흔들리고, 세게 흔들면 5000으로 화면을 가로질러 격렬히 여러 번 튕긴다.
  /// 안정화(§5)의 2단 마찰·정지 임계가 빠르게 잡아주므로 흔들기를 멈추면 ~1.2s에 정착한다.
  void addImpulse(Offset dir, double strength) {
    vel += dir * (strength * 5000);
    _bumpWobble(strength);
  }

  /// 누르기 홀드 시작(GST-03, v3 §2). [localPos]는 누른 화면 좌표.
  ///
  /// 침몰 축([pressDir])은 "누른 지점 → 중심" 방향(정중앙이면 위에서 누른 듯
  /// `Offset(0, -1)`). 이후 떼기 전까지 [update]가 깊이를 0.45s에 걸쳐 0→1로
  /// 차올린다. painter는 [pressDepth]/[pressDir]만 읽어 본체 변형으로 표현한다.
  void pressStart(Offset localPos) {
    final toCenter = pos - localPos;
    final d = toCenter.distance;
    // 정중앙이면 영벡터 회피 — 위에서 누른 느낌으로 위쪽(-y)을 기본 축.
    _pressDir = d > 0.001 ? toCenter / d : const Offset(0, -1);
    // v9 §2-B: 접촉점(중심 기준 로컬좌표)을 radius*0.7 안으로 clamp해 저장 —
    // 본체 가장자리를 눌러도 덴트가 표면 안에 머물게.
    final contact = localPos - pos;
    final cd = contact.distance;
    final maxContact = radius * 0.7;
    _pressContact = cd > maxContact ? contact / cd * maxContact : contact;
    _holding = true;
    // 진행 중이던 복원이 있더라도 현재 깊이에서 이어 눌리도록 _curDepth 유지.
    // 홀드 시간은 현재 깊이에 해당하는 시점부터 다시 적분(이어 누르기 자연스럽게).
    _holdT = _depthToHoldTime(_curDepth);
    _releaseT = -1;
    // 미세 틱: 이미 통과한 정점은 다시 울리지 않도록 현재 깊이 기준으로 무장.
    _tick50Armed = _curDepth >= 0.5;
    _tick85Armed = _curDepth >= 0.85;
  }

  /// 누르기 홀드 종료(v3 §2). 현재 깊이에서 elastic 복원을 시작한다.
  void pressEnd() {
    if (!_holding) return;
    _holding = false;
    _releaseDepth = _curDepth;
    _releaseT = 0;
  }

  /// 누르기 침몰을 **즉시 0으로 리셋**(복원 elastic 팝 없이, v6 §3).
  ///
  /// [pressEnd]는 탭/홀드를 뗄 때 현재 깊이에서 elasticOut으로 "톡" 차오르는
  /// 복원 팝을 내지만, 이 메서드는 드래그/쓰다듬기로 전환되는 순간 builder가
  /// 호출해 **팝 없이 조용히** 침몰 흔적("꿀렁" 잔상)을 즉시 지운다.
  /// 호출 직후 [pressDepth]는 0을 반환하고, [consumePressHoldTick]은 더 이상
  /// true를 내지 않으며(틱 무장 해제), 복원 정점 햅틱도 발생하지 않는다.
  void pressCancel() {
    _holding = false;
    _holdT = 0;
    // 복원(elastic) 비활성 — _releaseT<0이면 update에서 복원 분기를 타지 않는다.
    _releaseT = -1;
    _releaseDepth = 0;
    // 깊이 즉시 0(팝 없이 평상 상태).
    _curDepth = 0;
    // 미세 틱 무장/대기 모두 해제 — 전환 순간 톡 소리가 새지 않도록.
    _tick50Armed = false;
    _tick85Armed = false;
    _tickPending = false;
  }

  /// painter가 읽는 현재 침몰 깊이(0~1). 0=평소, 1=최대 침몰.
  double get pressDepth => _curDepth;

  /// 덴트 축(누른 지점 → 중심 정규화). painter 본체 변형 방향.
  Offset get pressDir => _pressDir;

  /// 누르기 접촉점(중심 기준 로컬좌표, radius*0.7로 clamp). painter가 이 자리에
  /// "뽁" 국소 오목 덴트를 그린다. pressDepth=0이면 그리지 않으므로 게이트는 깊이가 한다.
  Offset get pressContact => _pressContact;

  /// 침몰 중 깊이가 0.5·0.85 정점을 통과한 프레임에 true를 1회 반환하고 소비.
  ///
  /// home_screen `_onTick`이 읽어 미세 틱 햅틱([pressHoldTick])을 발사한다 —
  /// 물리 깊이와 한 소스에서 동기되어 desync를 방지한다(v3 §2, 계약 v3).
  bool consumePressHoldTick() {
    if (_tickPending) {
      _tickPending = false;
      return true;
    }
    return false;
  }

  /// 홀드 깊이(ease-out: 처음 빠르게, 끝으로 느리게)를 깊이값으로 환산.
  /// t=0→0, t=_holdInDur→1. easeOutCubic(1-(1-x)^3).
  static double _holdDepthFor(double holdT) {
    final x = (holdT / _holdInDur).clamp(0.0, 1.0);
    final inv = 1 - x;
    return 1 - inv * inv * inv;
  }

  /// 깊이값을 ease-out 곡선의 역으로 환산(이어 누르기 시 홀드 시간 복원용).
  static double _depthToHoldTime(double depth) {
    final d = depth.clamp(0.0, 1.0);
    // depth = 1-(1-x)^3  →  x = 1 - (1-depth)^(1/3)
    final x = 1 - pow(1 - d, 1 / 3).toDouble();
    return x * _holdInDur;
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

  /// 손으로 잡아 끌기(굴리기 GST-02). [target]은 손가락 위치.
  ///
  /// [ease]는 추종 강도(v4 §3):
  /// - 1.0(기본·roll 커밋 후): clamped target으로 full 추종(pos=target, vel=delta*14).
  /// - <1.0(pending용): 현재 pos에서 clamped target 쪽으로 ease 비율만 이동하는
  ///   부드러운 부분 추종(살짝 따라오되 확 안 날아감). vel·squash·wobble은 모두
  ///   "실제 이동량(delta)" 기준이라 작은 출렁임만 나고 위치는 거의 제자리 유지.
  ///   builder는 pending에서 `grab(pos, ease:0.3)`, roll 커밋 후 `grab(pos)`를 부른다.
  void grab(Offset target, {double ease = 1.0}) {
    grabbed = true;
    final e = ease.clamp(0.0, 1.0);
    final clamped = Offset(
      target.dx.clamp(bounds.left + radius, bounds.right - radius),
      target.dy.clamp(bounds.top + radius, bounds.bottom - radius),
    );
    // ease<1이면 target 쪽으로 ease 비율만 이동(부분 추종). ease=1이면 next=clamped.
    final next = e >= 1.0 ? clamped : pos + (clamped - pos) * e;
    // 실제 이동량(delta) 기준으로 출렁임·변형 유발 — pending은 작게, roll은 크게.
    final delta = next - pos;
    // 손가락 추종 속도 → 출렁임 유발. v3 §3: 12→14로 살짝 더 붙게(즉각 추종 유지).
    vel = delta * 14;
    // 변형은 끄는 반대 방향으로
    final d = delta.distance;
    if (d > 0.001) {
      squash = min(0.5, d / radius);
      squashDir = delta / d;
    }
    _bumpWobble(min(0.4, d / radius));
    pos = next;
  }

  void release() {
    grabbed = false;
  }

  /// 제자리 쓰다듬기(GST-04). [step]은 직전 프레임 대비 손가락 이동량,
  /// [localPos]는 손가락의 현재 화면 좌표(위치 반응용, v8 §1-B).
  ///
  /// 공은 전혀 옮기지 않고(완전 제자리, pos·vel 불변) 현 위치에서 표면만 반응한다.
  /// 표면 출렁임([wobbleAmp])·약한 squash에 더해, 손가락이 닿는 자리를 중심 기준
  /// 로컬좌표([_strokeContact])로 잡아 painter가 그 위치에 화이트 광택을 그리게 한다.
  void stroke(Offset step, Offset localPos) {
    grabbed = true; // update의 물리 적분을 멈춰 제자리 유지
    final len = step.distance;
    if (len > 0.001) {
      // v4 §3: 공은 전혀 움직이지 않는다(완전 제자리). 표면 출렁임/squash만 키워
      // "공은 가만, 표면만 반응"하게 — 굴리기와 명확히 구분. (이전 `pos += step*0.06` 제거)
      // 쓸리는 방향으로 약한 squash (dreamy: 천천히 차오르도록 계수 낮춤).
      // 누르기 덴트와 달리 얕게 유지 — v3 §2 차별화. v5 §2: 표면이 더 살아 출렁이도록
      // 상한 0.18→0.24로 소폭 상향(쓰다듬기 인지 강화, 제자리는 그대로 유지).
      squash = min(0.24, squash + len / radius * 0.35);
      squashDir = step / len;
    }
    // v8 §1-B: 손가락 닿는 자리를 중심 기준 로컬좌표로(공은 제자리이므로 pos가 중심).
    // 공 밖으로 벗어나도 표면에 머물도록 radius*0.85 원 안으로 clamp.
    final contact = localPos - pos;
    final cd = contact.distance;
    final maxContact = radius * 0.85;
    _strokeContact =
        cd > maxContact ? contact / cd * maxContact : contact;
    // 접촉 세기 상승(이동 길이 비례). update에서 ~1.2s에 0으로 감쇠.
    _strokeAmp = (_strokeAmp + len / radius * 0.5).clamp(0.0, 1.0);
    vel = Offset.zero; // fling 금지
    // 매 move마다 살짝씩만 더해 부드럽게 출렁이게(스파이크 방지) — update의
    // wobbleAmp 감쇠(-dt*1.4)와 맞물려 멈추면 자연 감쇠한다.
    // v5 §2: 출렁임을 더 또렷이 — 상한 0.30→0.45, 계수 0.75→0.95.
    _bumpWobble(min(0.45, len / radius * 0.95));
  }

  /// 한 프레임 물리 적분.
  /// [gravity]는 외부에서 주는 가속도(이미 스케일됨). 홈 화면은 `Offset.zero` 전달.
  void update(double dt, Offset gravity) {
    lastImpact = 0;
    _wobblePhase += dt * 18;
    wobbleAmp = (wobbleAmp - dt * 1.4).clamp(0.0, 1.0);
    squash = (squash - dt * 3.0).clamp(0.0, 1.0);
    // v8 §1-B: 쓰다듬기 접촉 광택 세기 시간 감쇠 — 손가락이 멈추면 ~1.2s에 0으로.
    _strokeAmp = (_strokeAmp - dt * 0.85).clamp(0.0, 1.0);

    // ── 누르기 홀드 침몰 / elastic 복원(v3 §2) ──
    // grabbed 여부와 무관하게 항상 갱신(누르기는 제자리 홀드라 grab과 배타적이지만
    // 안전하게 매 프레임 진행).
    if (_holding) {
      // 떼기 전까지 시간 누적 → 0.45s 상한에서 깊이 1.0에 머묾.
      _holdT = (_holdT + dt).clamp(0.0, _holdInDur);
      final prev = _curDepth;
      _curDepth = _holdDepthFor(_holdT);
      _armHoldTicks(prev, _curDepth);
    } else if (_releaseT >= 0) {
      // 복원: _releaseDepth에서 elasticOut으로 0까지(살짝 오버슈트), 0.5s.
      _releaseT += dt;
      final t = (_releaseT / _releaseDur).clamp(0.0, 1.0);
      // (1 - elasticOut)에 시작 깊이를 곱해 현재 깊이에서부터 차오르게.
      _curDepth = (_releaseDepth * (1 - _elasticOut(t))).clamp(0.0, 1.0);
      if (t >= 1.0) {
        _curDepth = 0;
        _releaseT = -1;
      }
    }

    if (grabbed) return; // 잡고 있는 동안 물리 정지(grab에서 직접 위치 갱신)

    // 중력(기울기) 적용
    vel += gravity * dt;

    // ── 2단 마찰(v3 §5): 빠르면 활발히 튀게 약감속, 느리면 부드럽게 잦아듦 ──
    // v2(1.0/3.2)에서 완화 → 흔들기·fling이 미끄러지듯 ~1.2s에 멈춤.
    final speed = vel.distance;
    final friction = speed > _kFastSpeed ? 0.9 : 1.7;
    vel *= (1 - friction * dt);

    pos += vel * dt;

    final collided = _collideWalls();

    // ── 정지 임계(snap-to-stop, v3 §5): 거의 멈췄을 때만 살짝 정리(10px/s) ──
    // 벽 충돌 직후 프레임은 제외(튕김 속도를 죽이지 않도록).
    if (!collided && vel.distance < _kStopSpeed) {
      vel = Offset.zero;
    }
  }

  /// 침몰 중 깊이가 0.5·0.85 정점을 (상향) 통과하면 미세 틱 1회 무장.
  void _armHoldTicks(double prev, double cur) {
    if (!_tick50Armed && prev < 0.5 && cur >= 0.5) {
      _tick50Armed = true;
      _tickPending = true;
    }
    if (!_tick85Armed && prev < 0.85 && cur >= 0.85) {
      _tick85Armed = true;
      _tickPending = true;
    }
  }

  // 안정화 튜닝 상수(v3 §5, 실기기 체감 조정 대상)
  static const double _kFastSpeed = 900; // px/s 초과 시 약감속(0.9)
  static const double _kStopSpeed = 10; // px/s 미만 시 snap-to-stop(거의 멈췄을 때만)

  /// 벽 충돌 처리. 이번 프레임에 실제 반발(튕김)이 일어났으면 true.
  /// (정지 임계가 튕김 직후 속도를 죽이지 않도록 호출부가 참고.)
  bool _collideWalls() {
    const restitution = 0.55; // v3 §5: 0.5→0.55, 살짝 더 탱탱.
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
