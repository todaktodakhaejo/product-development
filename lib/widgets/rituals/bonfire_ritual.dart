import 'dart:math';

import 'package:flutter/material.dart';

import '../../services/audio/sound_service.dart';
import '../../services/haptics/haptics.dart';
import '../../state/app_services.dart';
import '../../theme/app_colors.dart';
import 'ritual_header.dart';

/// ③ 모닥불에 태우기 (PRODUCT_SPEC 4.4 ③).
///
/// 종이를 천천히 아래로 끌어 불 위에 올리면 점화되어, 아래→위로
/// 천천히 타들어가(약 12초) 재가 되어 사라진다.
/// 햅틱: 타는 동안 pressHum 연속 진동(아래→위 방향감) (실기기).
class BonfireRitual extends StatefulWidget {
  const BonfireRitual({super.key, required this.onComplete});

  final VoidCallback onComplete;

  @override
  State<BonfireRitual> createState() => _BonfireRitualState();
}

class _BonfireRitualState extends State<BonfireRitual>
    with TickerProviderStateMixin {
  late final AnimationController _flame = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  late final AnimationController _burn = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 12),
  );

  double _paperDrop = 0; // 종이를 아래로 내린 정도(px)
  bool _ignited = false;

  @override
  void initState() {
    super.initState();
    _burn.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        AppServicesScope.of(context).haptics.stop();
        widget.onComplete();
      }
    });
  }

  @override
  void dispose() {
    _flame.dispose();
    _burn.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails d, double areaHeight) {
    if (_ignited) return;
    final limit = areaHeight * 0.42;
    setState(() => _paperDrop = (_paperDrop + d.delta.dy).clamp(0.0, limit).toDouble());
    if (_paperDrop >= limit * 0.96) _ignite();
  }

  void _ignite() {
    _ignited = true;
    final services = AppServicesScope.of(context);
    services.haptics.startContinuous(HapticPattern.pressHum);
    services.sound.play(SoundKey.burn);
    _burn.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        RitualHeader(
          title: '모닥불에 태우기',
          hint: _ignited ? '재가 되어 사라져요' : '종이를 불 위로 천천히 내려요',
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final h = constraints.maxHeight;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: (d) => _onDragUpdate(d, h),
                child: AnimatedBuilder(
                  animation: Listenable.merge([_flame, _burn]),
                  builder: (context, _) {
                    return CustomPaint(
                      size: Size(constraints.maxWidth, h),
                      painter: _BonfirePainter(
                        paperDrop: _paperDrop,
                        flame: _flame.value,
                        burn: _burn.value,
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _BonfirePainter extends CustomPainter {
  _BonfirePainter({
    required this.paperDrop,
    required this.flame,
    required this.burn,
  });

  final double paperDrop;
  final double flame;
  final double burn;

  @override
  void paint(Canvas canvas, Size size) {
    final fireBaseY = size.height * 0.84;
    final cx = size.width / 2;

    // 불빛 글로우
    canvas.drawCircle(
      Offset(cx, fireBaseY - 20),
      90 + flame * 12,
      Paint()
        ..shader = RadialGradient(
          colors: [
            AppColors.accentFireWarm.withValues(alpha: 0.45),
            AppColors.accentFireWarm.withValues(alpha: 0.0),
          ],
        ).createShader(
          Rect.fromCircle(center: Offset(cx, fireBaseY - 20), radius: 110),
        ),
    );

    // 종이 (아래로 내려옴, 타들어가면 아래부터 사라짐)
    final paperW = size.width * 0.46;
    final paperH = size.height * 0.30;
    final paperTop = size.height * 0.10 + paperDrop;
    final burnedFromBottom = paperH * burn;
    final visibleH = paperH - burnedFromBottom;
    if (visibleH > 1) {
      final rect = Rect.fromLTWH(cx - paperW / 2, paperTop, paperW, visibleH);
      canvas.drawRect(rect, Paint()..color = AppColors.paper);
      // 타는 경계의 그을음
      if (burn > 0) {
        canvas.drawRect(
          Rect.fromLTWH(cx - paperW / 2, paperTop + visibleH - 6, paperW, 6),
          Paint()..color = const Color(0xFF3A2E2A),
        );
      }
    }

    // 불꽃 (3겹 teardrop, flicker)
    void flameShape(double w, double hgt, Color color, double phase) {
      final flick = sin((flame + phase) * 2 * pi) * 6;
      final path = Path()
        ..moveTo(cx, fireBaseY)
        ..quadraticBezierTo(cx - w, fireBaseY - hgt * 0.5,
            cx + flick * 0.3, fireBaseY - hgt)
        ..quadraticBezierTo(cx + w, fireBaseY - hgt * 0.5, cx, fireBaseY)
        ..close();
      canvas.drawPath(path, Paint()..color = color);
    }

    flameShape(46, 130 + flame * 20, AppColors.accentFireWarm, 0.0);
    flameShape(32, 96 + flame * 16, AppColors.accentFireHot, 0.3);
    flameShape(18, 64 + flame * 10, AppColors.objectHighlight, 0.6);

    // 재(ember)가 위로 떠오름
    if (burn > 0) {
      final rnd = Random(11);
      final emberPaint = Paint()..color = AppColors.accentFireWarm;
      for (var i = 0; i < 10; i++) {
        final local = ((burn * 1.6) - rnd.nextDouble()).clamp(0.0, 1.0);
        if (local <= 0) continue;
        final ex = cx + (rnd.nextDouble() - 0.5) * paperW;
        final ey = fireBaseY - 40 - local * size.height * 0.4;
        canvas.drawCircle(
          Offset(ex, ey),
          1.5 + rnd.nextDouble() * 1.5,
          emberPaint..color = AppColors.accentFireWarm.withValues(alpha: 1 - local),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_BonfirePainter old) =>
      old.paperDrop != paperDrop || old.flame != flame || old.burn != burn;
}
