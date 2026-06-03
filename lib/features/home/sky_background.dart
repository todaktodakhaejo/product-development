import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 시간대 배경의 텍스트 가독성 톤.
///
/// - [light]: 밝은 낮 배경 → 어두운 글씨 권장.
/// - [warm]: 따뜻한 새벽/노을 중간 톤 → 어두운 글씨 권장.
/// - [dark]: 깊은 밤·여명 → 밝은 글씨 권장.
enum SkyTone { light, warm, dark }

/// 하루 시간대를 그라데이션으로 그리는 배경 위젯.
///
/// 5개 앵커(predawn·dawn·day·dusk·night)를 연속 시각 `t = hour + min/60`으로
/// 보간한다(24↔0 wrap). 내부 [Ticker]가 매 프레임 `DateTime.now()`를 다시 읽어
/// 미세하게 lerp하므로, 화면을 켜둔 채 시간이 흘러도 노을→밤이 **끊김 없이**
/// 흐른다(seamless drift). 단계가 "뚝" 바뀌는 하드 컷이 없다.
///
/// 위에 [child]를 얹어 쓴다(홈 화면이 `AppBackground` 대신 이걸로 감싼다).
class SkyBackground extends StatefulWidget {
  const SkyBackground({super.key, required this.child});

  final Widget child;

  @override
  State<SkyBackground> createState() => _SkyBackgroundState();
}

class _SkyBackgroundState extends State<SkyBackground>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  // 현재 시각의 연속 hour(0~24). Ticker가 갱신.
  double _t = _hourOf(DateTime.now());

  @override
  void initState() {
    super.initState();
    // 매 프레임 현재 시각을 다시 읽어 _t를 갱신 → 미세 lerp(seamless drift).
    // 풀스크린 blur 없이 그라데이션만 다시 그리므로 비용은 가볍다.
    _ticker = createTicker((_) {
      final now = _hourOf(DateTime.now());
      // hour는 1분에 1/60밖에 안 변하므로 사실상 매 프레임 거의 동일하지만,
      // 시간이 실제로 흐르면 부드럽게 따라간다. 변화가 있을 때만 setState.
      if ((now - _t).abs() > 1e-5) {
        setState(() => _t = now);
      }
    });
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stops = _skyStopsAt(_t); // top→bottom 3색
    final nightW = _nightWeight(_t); // 밤/여명 가중치(별)
    final warmW = _warmWeight(_t); // 새벽/노을 가중치(따뜻한 글로우)

    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 1) 시간대 그라데이션(연속 morph).
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: stops,
                stops: const [0.0, 0.5, 1.0],
              ),
            ),
          ),
          // 2) 깊이 오버레이(과하지 않게): 밤엔 별, 새벽/노을엔 따뜻한 글로우.
          //    가중치가 0이면 CustomPaint가 아무것도 그리지 않으므로 부담 없음.
          if (nightW > 0.01 || warmW > 0.01)
            Positioned.fill(
              child: CustomPaint(
                painter: _SkyOverlayPainter(
                  nightWeight: nightW,
                  warmWeight: warmW,
                  warmColor: stops.last, // 하단 따뜻한 색을 글로우에 재사용
                ),
              ),
            ),
          // 3) 실제 내용.
          widget.child,
        ],
      ),
    );
  }
}

// ── 시간대 앵커 정의 ─────────────────────────────────────────────
// 각 앵커: (앵커 hour, [top, mid, bottom] 3색, tone).
class _SkyAnchor {
  const _SkyAnchor(this.hour, this.colors, this.tone);
  final double hour;
  final List<Color> colors; // top→bottom 3스톱
  final SkyTone tone;
}

const List<_SkyAnchor> _anchors = [
  // predawn 4.5 (dark)
  _SkyAnchor(4.5, [Color(0xFF0F2848), Color(0xFF2E6FA0), Color(0xFFF0D0B8)],
      SkyTone.dark),
  // dawn 6.5 (warm)
  _SkyAnchor(6.5, [Color(0xFFA8C8E8), Color(0xFFF5C8A8), Color(0xFFD8C8C0)],
      SkyTone.warm),
  // day 13 (light)
  _SkyAnchor(13.0, [Color(0xFFFFE8E4), Color(0xFFD8C5DD), Color(0xFFB8C5D9)],
      SkyTone.light),
  // dusk 18 (dark)
  _SkyAnchor(18.0, [Color(0xFF2A3A6B), Color(0xFF8B6890), Color(0xFFF8C898)],
      SkyTone.dark),
  // night 23 (dark)
  _SkyAnchor(23.0, [Color(0xFF050811), Color(0xFF102448), Color(0xFF1A3868)],
      SkyTone.dark),
];

double _hourOf(DateTime now) => now.hour + now.minute / 60 + now.second / 3600;

/// 두 앵커 사이의 wrap-aware 거리(앞 앵커 hour → 뒤 앵커 hour, 24 wrap 고려).
double _forwardSpan(double from, double to) {
  final d = to - from;
  return d >= 0 ? d : d + 24;
}

/// 현재 연속 시각 [t](0~24)에 대해 양 옆 앵커를 찾아 스톱별 [Color.lerp]한
/// top→bottom 3색을 돌려준다. 24↔0을 넘어가는 구간(night 23 → predawn 4.5)도
/// 자연스럽게 wrap 보간한다.
List<Color> _skyStopsAt(double t) {
  final (lo, hi, f) = _segmentAt(t);
  return [
    Color.lerp(lo.colors[0], hi.colors[0], f)!,
    Color.lerp(lo.colors[1], hi.colors[1], f)!,
    Color.lerp(lo.colors[2], hi.colors[2], f)!,
  ];
}

/// [t]를 감싸는 (이전 앵커, 다음 앵커, 진행도 0~1)를 wrap-aware로 찾는다.
(_SkyAnchor, _SkyAnchor, double) _segmentAt(double t) {
  for (var i = 0; i < _anchors.length; i++) {
    final lo = _anchors[i];
    final hi = _anchors[(i + 1) % _anchors.length];
    final span = _forwardSpan(lo.hour, hi.hour);
    final into = _forwardSpan(lo.hour, t);
    // into가 0~span 안이면 이 세그먼트에 속한다.
    if (into <= span + 1e-9) {
      final f = span < 1e-9 ? 0.0 : (into / span).clamp(0.0, 1.0);
      return (lo, hi, f);
    }
  }
  // 도달 불가(안전 폴백): 첫 앵커.
  return (_anchors.first, _anchors.first, 0.0);
}

/// 현재 시각의 텍스트 톤. 양 옆 앵커 tone을 진행도로 선택하되, 경계에서 톤이
/// 뚝 바뀌지 않게 진행도 절반(0.5)을 기준으로 가까운 앵커의 tone을 따른다.
/// builder가 글씨/카운트 색 가독성에 사용한다(light/warm=어두운 글씨, dark=밝은 글씨).
SkyTone skyToneAt(DateTime now) {
  final t = _hourOf(now);
  final (lo, hi, f) = _segmentAt(t);
  return f < 0.5 ? lo.tone : hi.tone;
}

// ── 깊이 오버레이 가중치 ─────────────────────────────────────────
// 시각별 0~1 가중치. 부드러운 종 모양(가까운 앵커일수록 1)으로 fade.

/// 특정 중심 hour 주변의 종 모양 가중치(반폭 [half] 시간). wrap-aware.
double _bell(double t, double center, double half) {
  // 중심과의 wrap 최단 거리.
  var d = (t - center).abs();
  if (d > 12) d = 24 - d;
  if (d >= half) return 0;
  final x = d / half; // 0(중심)~1(가장자리)
  return 1 - x * x * (3 - 2 * x); // smoothstep 역(중심 1 → 가장자리 0)
}

/// 밤·여명 가중치(별 표시용). night 23 + predawn 4.5 부근.
double _nightWeight(double t) =>
    max(_bell(t, 23.0, 5.0), _bell(t, 1.0, 4.0)); // 자정 전후 폭넓게

/// 새벽·노을 가중치(따뜻한 글로우용). dawn 6.5 + dusk 18 부근.
double _warmWeight(double t) => max(_bell(t, 6.5, 2.5), _bell(t, 18.0, 2.5));

/// 별(밤) + 따뜻한 글로우(새벽/노을) 오버레이. 둘 다 가중치 fade로 dreamy하게.
/// 별은 seed 고정으로 결정적 재현(깜빡임/이동 없는 잔잔한 점광).
class _SkyOverlayPainter extends CustomPainter {
  _SkyOverlayPainter({
    required this.nightWeight,
    required this.warmWeight,
    required this.warmColor,
  });

  final double nightWeight; // 0~1
  final double warmWeight; // 0~1
  final Color warmColor; // 하단 따뜻한 색(노을/새벽)

  // 결정적 별 배치(seed 고정). 화면 비율 좌표(0~1)로 저장 → 어떤 크기에도 재현.
  static final List<_Star> _stars = _buildStars();

  static List<_Star> _buildStars() {
    final rnd = Random(7);
    return List.generate(48, (_) {
      return _Star(
        rnd.nextDouble(),
        // 별은 상단~중단에 더 많이(하늘). 하단 30%엔 적게.
        rnd.nextDouble() * 0.7,
        0.4 + rnd.nextDouble() * 0.9, // 반경(px 근사)
        0.3 + rnd.nextDouble() * 0.7, // 밝기 편차
      );
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    // 따뜻한 글로우: 하단에서 위로 번지는 부드러운 빛(새벽/노을 가중치).
    if (warmWeight > 0.01) {
      final glow = Paint()
        ..shader = RadialGradient(
          center: const Alignment(0.0, 1.2), // 화면 하단 바깥에서 떠오름
          radius: 1.1,
          colors: [
            warmColor.withValues(alpha: 0.45 * warmWeight),
            warmColor.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 1.0],
        ).createShader(Offset.zero & size);
      canvas.drawRect(Offset.zero & size, glow);
    }

    // 별: 밤 가중치 비례 opacity. 잔잔한 점광(blur 미세).
    if (nightWeight > 0.01) {
      final star = Paint()
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.6);
      for (final s in _stars) {
        star.color = Colors.white
            .withValues(alpha: (0.8 * s.brightness * nightWeight).clamp(0.0, 0.85));
        canvas.drawCircle(
          Offset(s.x * size.width, s.y * size.height),
          s.r,
          star,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SkyOverlayPainter old) =>
      old.nightWeight != nightWeight ||
      old.warmWeight != warmWeight ||
      old.warmColor != warmColor;
}

class _Star {
  const _Star(this.x, this.y, this.r, this.brightness);
  final double x; // 0~1 화면 폭 비율
  final double y; // 0~1 화면 높이 비율
  final double r; // 반경(px)
  final double brightness; // 0~1
}
