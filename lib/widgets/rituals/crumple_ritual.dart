import 'dart:math';

import 'package:flutter/material.dart';

import '../../services/audio/sound_service.dart';
import '../../services/haptics/haptics.dart';
import '../../state/app_services.dart';
import '../../theme/app_colors.dart';
import 'ritual_header.dart';

/// ② 구겨서 던지기 (PRODUCT_SPEC 4.4 ②).
///
/// 종이를 탭할수록 더 작게 구겨지고(세게 모을수록 더 작은 공), 충분히 구기면
/// 세게 휘둘러(플링) 던져 날린다.
/// 햅틱: 구길 때 pressHum, 던질 때 burst (실기기).
class CrumpleRitual extends StatefulWidget {
  const CrumpleRitual({super.key, required this.onComplete});

  final VoidCallback onComplete;

  @override
  State<CrumpleRitual> createState() => _CrumpleRitualState();
}

class _CrumpleRitualState extends State<CrumpleRitual>
    with SingleTickerProviderStateMixin {
  static const int _maxLevel = 4;
  int _level = 0;
  bool _done = false;

  late final AnimationController _fly = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  Offset _flyDir = Offset.zero;

  bool get _ready => _level >= _maxLevel;

  @override
  void initState() {
    super.initState();
    _fly.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) widget.onComplete();
    });
  }

  @override
  void dispose() {
    _fly.dispose();
    super.dispose();
  }

  void _crumple() {
    if (_ready || _done) return;
    setState(() => _level++);
    final services = AppServicesScope.of(context);
    services.haptics.play(HapticPattern.pressHum);
    services.sound.play(SoundKey.crumple);
  }

  void _onPanEnd(DragEndDetails d) {
    if (!_ready || _done) return;
    final v = d.velocity.pixelsPerSecond;
    if (v.distance < 240) return; // 살짝은 안 됨 — 세게 휘둘러야 던져짐
    _done = true;
    _flyDir = v / v.distance;
    AppServicesScope.of(context).haptics.play(HapticPattern.burst);
    _fly.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        RitualHeader(
          title: '구겨서 던지기',
          hint: _done
              ? '멀리 날아가요'
              : _ready
                  ? '이제 세게 휘둘러 던져요'
                  : '종이를 탭해서 구겨요',
        ),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _crumple,
            onPanEnd: _onPanEnd,
            child: AnimatedBuilder(
              animation: _fly,
              builder: (context, _) {
                final p = Curves.easeIn.transform(_fly.value);
                final offset = _flyDir * (p * 720);
                return Center(
                  child: Transform.translate(
                    offset: offset,
                    child: Opacity(
                      opacity: 1 - p,
                      child: CustomPaint(
                        size: const Size(220, 220),
                        painter: _CrumplePainter(
                          level: _level,
                          maxLevel: _maxLevel,
                        ),
                      ),
                    ),
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

class _CrumplePainter extends CustomPainter {
  _CrumplePainter({required this.level, required this.maxLevel});

  final int level;
  final int maxLevel;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final t = level / maxLevel; // 0~1 구겨진 정도
    final side = size.width * (0.62 - t * 0.32); // 구길수록 작아짐
    final radius = 12 + t * (side / 2 - 12); // 구길수록 둥글게(공에 가까움)

    final rect = Rect.fromCenter(center: center, width: side, height: side);
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));

    canvas.drawShadow(Path()..addRRect(rrect), Colors.black26, 8, false);
    canvas.drawRRect(rrect, Paint()..color = AppColors.paper);

    // 구김 주름 (레벨에 따라 증가)
    final rnd = Random(level * 17 + 3);
    final linePaint = Paint()
      ..color = AppColors.paperLine.withValues(alpha: 0.6)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    final count = level * 5;
    for (var i = 0; i < count; i++) {
      final a = rnd.nextDouble() * 2 * pi;
      final len = side * (0.12 + rnd.nextDouble() * 0.22);
      final start = center +
          Offset(
            (rnd.nextDouble() - 0.5) * side * 0.7,
            (rnd.nextDouble() - 0.5) * side * 0.7,
          );
      final end = start + Offset(cos(a) * len, sin(a) * len);
      canvas.drawLine(start, end, linePaint);
    }
  }

  @override
  bool shouldRepaint(_CrumplePainter old) => old.level != level;
}
