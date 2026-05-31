import 'dart:math';

import 'package:flutter/material.dart';

import '../../services/audio/sound_service.dart';
import '../../services/haptics/haptics.dart';
import '../../state/app_services.dart';
import '../../theme/app_colors.dart';
import '../particle_field.dart';
import 'ritual_header.dart';

/// ① 파쇄기로 갈기 (PRODUCT_SPEC 4.4 ①).
///
/// 종이를 아래로 끌어 파쇄기에 밀어넣으면 잘린 조각이 쌓이고,
/// 다 들어가면 폭죽처럼 흩어지며(burst) 사라진다.
/// 햅틱: 갈리는 동안 shredGrind 연속 진동, 끝에 burst (실기기).
class ShredderRitual extends StatefulWidget {
  const ShredderRitual({super.key, required this.onComplete});

  final VoidCallback onComplete;

  @override
  State<ShredderRitual> createState() => _ShredderRitualState();
}

class _ShredderRitualState extends State<ShredderRitual>
    with SingleTickerProviderStateMixin {
  double _fed = 0; // 0~1, 종이가 파쇄기로 들어간 정도
  bool _done = false;

  late final AnimationController _burst = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );
  final List<Particle> _particles = Particle.generate(160, seed: 73);

  @override
  void initState() {
    super.initState();
    _burst.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        widget.onComplete();
      }
    });
  }

  @override
  void dispose() {
    _burst.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails d, double areaHeight) {
    if (_done) return;
    final inc = d.delta.dy / (areaHeight * 0.55); // 아래로 끌수록 증가
    if (inc <= 0) return;
    final next = (_fed + inc).clamp(0.0, 1.0).toDouble();
    if (next != _fed) {
      setState(() => _fed = next);
      final services = AppServicesScope.of(context);
      services.haptics.startContinuous(HapticPattern.shredGrind);
      services.sound.play(SoundKey.shred);
    }
    if (_fed >= 1.0 && !_done) _finish();
  }

  void _onDragEnd(DragEndDetails d) {
    AppServicesScope.of(context).haptics.stop();
  }

  void _finish() {
    _done = true;
    final haptics = AppServicesScope.of(context).haptics;
    haptics.stop();
    haptics.play(HapticPattern.burst);
    _burst.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        RitualHeader(
          title: '파쇄기로 갈기',
          hint: _done ? '흩어져 사라져요' : '종이를 아래로 끌어 파쇄기에 넣어요',
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final h = constraints.maxHeight;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: (d) => _onDragUpdate(d, h),
                onVerticalDragEnd: _onDragEnd,
                child: AnimatedBuilder(
                  animation: _burst,
                  builder: (context, _) {
                    return CustomPaint(
                      size: Size(constraints.maxWidth, h),
                      painter: _ShredderPainter(
                        fed: _fed,
                        burst: _burst.value,
                        particles: _particles,
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

class _ShredderPainter extends CustomPainter {
  _ShredderPainter({
    required this.fed,
    required this.burst,
    required this.particles,
  });

  final double fed;
  final double burst;
  final List<Particle> particles;

  @override
  void paint(Canvas canvas, Size size) {
    final slotY = size.height * 0.5;
    final paperW = size.width * 0.5;
    final paperLeft = (size.width - paperW) / 2;
    final fullPaperH = size.height * 0.32;

    if (burst == 0) {
      // 남은 종이 (위에서 파쇄기로 내려감)
      final remainH = fullPaperH * (1 - fed);
      if (remainH > 1) {
        final top = slotY - remainH;
        final rrect = RRect.fromRectAndRadius(
          Rect.fromLTWH(paperLeft, top, paperW, remainH),
          const Radius.circular(6),
        );
        canvas.drawShadow(
          Path()..addRRect(rrect),
          Colors.black26,
          6,
          false,
        );
        canvas.drawRRect(rrect, Paint()..color = AppColors.paper);
      }

      // 잘린 조각이 슬롯 아래로 쌓임
      if (fed > 0) {
        const stripCount = 14;
        final stripW = paperW / stripCount;
        final pileH = size.height * 0.30 * fed;
        final rnd = Random(7);
        for (var i = 0; i < stripCount; i++) {
          final jitter = (rnd.nextDouble() - 0.5) * 6;
          final x = paperLeft + i * stripW + jitter;
          final hgt = pileH * (0.6 + rnd.nextDouble() * 0.4);
          canvas.drawRect(
            Rect.fromLTWH(x, slotY + 16, stripW * 0.7, hgt),
            Paint()..color = AppColors.paper.withValues(alpha: 0.9),
          );
        }
      }
    } else {
      // 폭죽처럼 흩어짐 (particle_field 재사용)
      ParticlePainter(
        progress: burst,
        color: AppColors.paper,
        particles: particles,
      ).paint(canvas, size);
    }

    // 파쇄기 본체
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(paperLeft - 16, slotY - 14, paperW + 32, 28),
      const Radius.circular(8),
    );
    canvas.drawRRect(body, Paint()..color = const Color(0xFF6E6480));
    canvas.drawRect(
      Rect.fromLTWH(paperLeft - 8, slotY - 2, paperW + 16, 4),
      Paint()..color = Colors.black26,
    );
  }

  @override
  bool shouldRepaint(_ShredderPainter old) =>
      old.fed != fed || old.burst != burst;
}
