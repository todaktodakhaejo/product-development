import 'dart:math';

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// 살아있는 젤리 오브제 (PRODUCT_SPEC 4.1).
///
/// 현재는 idle breathing(숨쉬듯 부풂)과 탭/길게누르기 콜백만 갖춘 골격이다.
/// TODO(motion): 닫힌 베지어 제어점 N개로 젤리 윤곽 고도화, 드래그 일그러짐,
///               꼬집기 늘이기, 흔들기 팅김 등 제스처별 변형.
/// TODO(haptics): pressHum/rubTexture 연속 햅틱 + 제스처별 시그니처 사운드.
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
    with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onOpen,
      child: AnimatedBuilder(
        animation: _breath,
        builder: (context, _) {
          final t = Curves.easeInOut.transform(_breath.value);
          final scale = 0.96 + t * 0.08; // 숨쉬는 스케일
          return Transform.scale(
            scale: scale,
            child: CustomPaint(
              size: Size.square(widget.size),
              painter: _BlobPainter(phase: t),
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
