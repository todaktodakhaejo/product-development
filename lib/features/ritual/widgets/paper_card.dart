import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';

/// 작성한 감정 글이 적힌 종이. 의식 연출의 대상 오브제.
///
/// 모든 의식(태우기/파쇄/종이비행기/보석함)에서 공유한다. 종이는 항상 미세하게
/// 공중에 떠다니는 floating sway(은은한 회전·이동·호흡)를 가진다 — 명상 톤.
///
/// ⚠️ 흩날림은 **paint-only Transform** 으로만 적용한다. 레이아웃 크기·히트테스트
/// 영역(GestureDetector 좌표, _feed 거리 판정, _paperRect 마스크 위치, 스케일/접기
/// 계산)에는 일절 영향을 주지 않는다 — 시각 효과일 뿐 의식 로직 좌표는 불변.
class PaperCard extends StatefulWidget {
  const PaperCard({
    super.key,
    required this.text,
    this.width,
    this.height,
    this.shadow = true,
    this.float = true,
  });

  final String text;
  final double? width;
  final double? height;

  /// 종이 그림자(claymorphism 깊이). 기본 true(현행 유지).
  /// 태우기는 연소 중/완료에 그림자가 마스크 밖 사각형 잔상으로 남으므로
  /// `_BurningPaper`가 false로 렌더한다.
  final bool shadow;

  /// 공중 부유 floating sway on/off. 기본 true(모든 의식 자동 적용).
  /// 태우기 연소 중에는 자체 tremble이 주가 되므로 `_BurningPaper`가 false로
  /// 끈다(중복·과함 방지). idle/igniting·다른 의식에선 유지.
  final bool float;

  @override
  State<PaperCard> createState() => _PaperCardState();
}

class _PaperCardState extends State<PaperCard>
    with SingleTickerProviderStateMixin {
  // 흩날림 clock. bounded 컨트롤러를 긴 주기로 repeat 시켜 0→1 위상으로 쓴다.
  // ⚠️ AnimationController.unbounded()..repeat() 금지(_initialT>=0.0 크래시).
  // 충분히 긴 주기(30s)로 두고 sin 위상을 누적 시간으로 직접 계산한다.
  static const Duration _kPeriod = Duration(seconds: 30);
  late final AnimationController _ctrl;

  // 서로 다른 주기의 sin 합성으로 자연스러운 부유감(과하지 않게).
  static const double _rotAmp = 1.2 * math.pi / 180; // ±1.2°
  static const double _rotPeriod = 4.0; // s
  static const double _dyAmp = 4.0; // px
  static const double _dyPeriod = 3.3; // s
  static const double _dxAmp = 3.0; // px
  static const double _dxPeriod = 5.0; // s
  static const double _scaleAmp = 0.01; // 1.0 ± 0.01 호흡
  static const double _scalePeriod = 6.0; // s

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: _kPeriod);
    if (widget.float) _ctrl.repeat();
  }

  @override
  void didUpdateWidget(covariant PaperCard old) {
    super.didUpdateWidget(old);
    // 연소 진입 등으로 float이 꺼지면 sway 정지(태우기 tremble과 충돌 방지),
    // 다시 켜지면 재개. 누수 없이 같은 컨트롤러를 재사용.
    if (widget.float && !_ctrl.isAnimating) {
      _ctrl.repeat();
    } else if (!widget.float && _ctrl.isAnimating) {
      _ctrl.stop();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Widget _buildPaper() {
    return Container(
      width: widget.width,
      height: widget.height,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.paper,
        borderRadius: BorderRadius.circular(8),
        boxShadow: widget.shadow
            ? const [
                BoxShadow(
                  color: Colors.black54,
                  blurRadius: 24,
                  offset: Offset(0, 10),
                ),
              ]
            : null,
      ),
      child: Text(
        widget.text.isEmpty ? '…' : widget.text,
        style: const TextStyle(color: AppColors.ink, fontSize: 15, height: 1.6),
        overflow: TextOverflow.fade,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final paper = _buildPaper();
    if (!widget.float) return paper;

    // floating sway: 누적 초(period * value)로 서로 다른 주기의 sin 합성.
    // 모두 paint-only Transform — 레이아웃/히트테스트 불변.
    return AnimatedBuilder(
      animation: _ctrl,
      child: paper,
      builder: (context, child) {
        final tSec = _ctrl.value * _kPeriod.inSeconds;
        final rot = _rotAmp * math.sin(tSec / _rotPeriod * 2 * math.pi);
        final dx = _dxAmp * math.sin(tSec / _dxPeriod * 2 * math.pi + 1.3);
        final dy = _dyAmp * math.sin(tSec / _dyPeriod * 2 * math.pi);
        final scale =
            1.0 + _scaleAmp * math.sin(tSec / _scalePeriod * 2 * math.pi + 0.7);

        final m = Matrix4.identity()
          ..translateByDouble(dx, dy, 0, 1)
          ..rotateZ(rot)
          ..scaleByDouble(scale, scale, 1, 1);
        // origin 중앙 기준 회전/스케일이 보기 좋도록 Transform.alignment 사용.
        return Transform(
          transform: m,
          alignment: Alignment.center,
          filterQuality: FilterQuality.low,
          child: child,
        );
      },
    );
  }
}
