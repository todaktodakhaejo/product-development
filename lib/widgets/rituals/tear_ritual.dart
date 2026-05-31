import 'package:flutter/material.dart';

import '../../services/audio/sound_service.dart';
import '../../services/haptics/haptics.dart';
import '../../state/app_services.dart';
import '../../theme/app_colors.dart';
import '../particle_field.dart';
import 'ritual_header.dart';

/// ④ 종이 찢기 (PRODUCT_SPEC 4.4 ④).
///
/// 종이를 가로로 쓸어 찢는다(여러 번 가능). 충분히 찢으면 위로 쓸어올려
/// 조각들을 흩어 사라지게 한다.
/// 햅틱: 찢을 때마다 tear 임팩트, 흩을 때 burst (실기기).
class TearRitual extends StatefulWidget {
  const TearRitual({super.key, required this.onComplete});

  final VoidCallback onComplete;

  @override
  State<TearRitual> createState() => _TearRitualState();
}

class _TearRitualState extends State<TearRitual>
    with SingleTickerProviderStateMixin {
  static const int _need = 3;
  int _tears = 0;
  bool _scattered = false;

  late final AnimationController _scatter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  );
  final List<Particle> _particles = Particle.generate(150, seed: 51);

  bool get _ready => _tears >= _need;

  @override
  void initState() {
    super.initState();
    _scatter.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) widget.onComplete();
    });
  }

  @override
  void dispose() {
    _scatter.dispose();
    super.dispose();
  }

  void _onHorizontalDragEnd(DragEndDetails d) {
    if (_scattered || _ready) return;
    setState(() => _tears++);
    final services = AppServicesScope.of(context);
    services.haptics.play(HapticPattern.tear);
    services.sound.play(SoundKey.tear);
  }

  void _onVerticalDragEnd(DragEndDetails d) {
    if (_scattered || !_ready) return;
    if ((d.primaryVelocity ?? 0) >= -120) return; // 위로 쓸어올려야 함
    _scattered = true;
    AppServicesScope.of(context).haptics.play(HapticPattern.burst);
    _scatter.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        RitualHeader(
          title: '종이 찢기',
          hint: _scattered
              ? '흩어져 사라져요'
              : _ready
                  ? '위로 쓸어올려 흩어보내요'
                  : '종이를 가로로 쓸어 찢어요',
        ),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragEnd: _onHorizontalDragEnd,
            onVerticalDragEnd: _onVerticalDragEnd,
            child: AnimatedBuilder(
              animation: _scatter,
              builder: (context, _) {
                return CustomPaint(
                  size: Size.infinite,
                  painter: _TearPainter(
                    tears: _tears,
                    scatter: _scatter.value,
                    particles: _particles,
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _TearPainter extends CustomPainter {
  _TearPainter({
    required this.tears,
    required this.scatter,
    required this.particles,
  });

  final int tears;
  final double scatter;
  final List<Particle> particles;

  @override
  void paint(Canvas canvas, Size size) {
    if (scatter > 0) {
      ParticlePainter(
        progress: scatter,
        color: AppColors.paper,
        particles: particles,
      ).paint(canvas, size);
      return;
    }

    final center = size.center(Offset.zero);
    final paperW = size.width * 0.5;
    final paperH = size.height * 0.4;
    final pieces = tears + 1;
    final pieceW = paperW / pieces;
    final gap = tears * 5.0; // 찢을수록 조각이 벌어짐
    final totalW = paperW + gap * (pieces - 1);
    var x = center.dx - totalW / 2;
    final top = center.dy - paperH / 2;

    final paint = Paint()..color = AppColors.paper;
    for (var i = 0; i < pieces; i++) {
      final rect = Rect.fromLTWH(x, top, pieceW, paperH);
      canvas.drawShadow(Path()..addRect(rect), Colors.black26, 4, false);
      canvas.drawRect(rect, paint);
      x += pieceW + gap;
    }
  }

  @override
  bool shouldRepaint(_TearPainter old) =>
      old.tears != tears || old.scatter != scatter;
}
