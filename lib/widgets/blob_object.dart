import 'dart:math';

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// 살아있는 젤리 오브제 (PRODUCT_SPEC 4.1).
///
/// 인터랙션(웹/데스크톱에서 동작):
///  - 탭: 톡 눌렸다가 탄성 복원
///  - 끌기(드래그): 손가락 따라 이동 + 속도에 따라 늘어남, 놓으면 탄성 복원
///  - 길게 누르기: 분출 단계로 전환([onOpen])
///
/// TODO(motion): 베지어 제어점 기반 윤곽 변형, 꼬집기/회전.
/// TODO(haptics): 끌기 중 rubTexture 연속 햅틱, 기울여 굴리기(sensors_plus, 실기기).
class BlobObject extends StatefulWidget {
  const BlobObject({
    super.key,
    this.size = 220,
    this.onTap,
    this.onOpen,
  });

  final double size;

  /// 한 번 탭.
  final VoidCallback? onTap;

  /// 열기 제스처(길게 누르기) 완료 — 분출 단계로 전환.
  final VoidCallback? onOpen;

  @override
  State<BlobObject> createState() => _BlobObjectState();
}

class _BlobObjectState extends State<BlobObject>
    with TickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  )..repeat(reverse: true);

  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  // 드래그 후 제자리로 돌아오는 탄성 복원.
  late final AnimationController _return = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  );

  Offset _offset = Offset.zero; // 현재 변위
  Offset _springFrom = Offset.zero; // 복원 시작점
  Offset _dragDelta = Offset.zero; // 최근 드래그 델타(늘이기용)

  @override
  void initState() {
    super.initState();
    _return.addListener(() {
      final t = Curves.elasticOut.transform(_return.value);
      setState(() => _offset = Offset.lerp(_springFrom, Offset.zero, t)!);
    });
  }

  @override
  void dispose() {
    _breath.dispose();
    _press.dispose();
    _return.dispose();
    super.dispose();
  }

  void _handleTap() {
    widget.onTap?.call();
    _press.forward(from: 0).then((_) {
      if (mounted) _press.reverse();
    });
  }

  void _onPanStart(DragStartDetails _) => _return.stop();

  void _onPanUpdate(DragUpdateDetails d) {
    setState(() {
      _offset += d.delta;
      _dragDelta = d.delta;
    });
  }

  void _onPanEnd(DragEndDetails _) {
    setState(() => _dragDelta = Offset.zero);
    _springFrom = _offset;
    _return.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _handleTap,
      onLongPress: widget.onOpen,
      onPanStart: _onPanStart,
      onPanUpdate: _onPanUpdate,
      onPanEnd: _onPanEnd,
      child: AnimatedBuilder(
        animation: Listenable.merge([_breath, _press]),
        builder: (context, _) {
          final breath = Curves.easeInOut.transform(_breath.value);
          final breathScale = 0.96 + breath * 0.08;
          final press = Curves.easeOut.transform(_press.value);
          final pressScale = 1 - 0.12 * press;

          // 드래그 속도에 따른 방향성 늘이기(미세).
          final speed = _dragDelta.distance;
          final k = (speed / 36).clamp(0.0, 0.16);
          final horizontal = _dragDelta.dx.abs() >= _dragDelta.dy.abs();
          final sx = breathScale * pressScale * (1 + (horizontal ? k : -k * 0.6));
          final sy = breathScale * pressScale * (1 + (horizontal ? -k * 0.6 : k));

          return Transform.translate(
            offset: _offset,
            child: Transform(
              alignment: Alignment.center,
              transform: Matrix4.diagonal3Values(sx, sy, 1),
              child: CustomPaint(
                size: Size.square(widget.size),
                painter: _BlobPainter(phase: breath),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _BlobPainter extends CustomPainter {
  _BlobPainter({required this.phase});

  /// 0~1 호흡 위상.
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final base = size.width / 2 * 0.82;

    // TODO(motion): 사인 변조 원 → 베지어 제어점 기반 젤리 윤곽으로 교체.
    final path = Path();
    const segments = 72;
    for (var i = 0; i <= segments; i++) {
      final a = (i / segments) * 2 * pi;
      final wobble =
          1 + 0.03 * sin(a * 3 + phase * 2 * pi) + 0.02 * sin(a * 5 - phase * 2 * pi);
      final r = base * wobble;
      final p = center + Offset(cos(a) * r, sin(a) * r);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    path.close();

    // soft shadow (claymorphism)
    canvas.drawShadow(path, AppColors.objectCore.withValues(alpha: 0.4), 18, true);

    // 위에서 빛이 오는 느낌으로 음영 중심을 살짝 위로.
    final shaderRect = Rect.fromCircle(
      center: center.translate(0, -base * 0.18),
      radius: base * 1.15,
    );
    final paint = Paint()
      ..shader = const RadialGradient(
        colors: [
          AppColors.objectHighlight,
          AppColors.objectBase,
          AppColors.objectCore,
        ],
        stops: [0.0, 0.55, 1.0],
      ).createShader(shaderRect);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_BlobPainter oldDelegate) => oldDelegate.phase != phase;
}
