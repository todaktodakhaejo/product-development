import 'dart:math';

import 'package:flutter/material.dart';

import '../../../core/haptics.dart';
import '../../../state/session.dart';
import '../../../theme/app_theme.dart';
import '../../complete/complete_screen.dart';
import '../widgets/paper_card.dart';

/// RIT-09 종이비행기. 탭으로 접고(접는 단계마다 진동), 던지는 모션으로 날린다.
class PaperPlaneRitualScreen extends StatefulWidget {
  const PaperPlaneRitualScreen({super.key});

  @override
  State<PaperPlaneRitualScreen> createState() => _PaperPlaneRitualScreenState();
}

class _PaperPlaneRitualScreenState extends State<PaperPlaneRitualScreen>
    with TickerProviderStateMixin {
  late final AnimationController _fold;
  late final VoidCallback _detachFoldHaptics;
  late final AnimationController _fly;
  bool _folded = false;
  bool _finished = false;
  Offset _flyDir = const Offset(1, -1);
  double _flySpeed = 0; // 던지기 속도 정규화(0~1) → 비행 거리

  // 비행 글라이드 곡선(부드럽게 감속).
  late final Animation<double> _flyCurve =
      CurvedAnimation(parent: _fly, curve: Curves.easeOutCubic);

  @override
  void initState() {
    super.initState();
    _fold = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
    // 접기 단계감: light·light·medium(마지막 접힘이 가장 단단). 큐를 빌더로 통일.
    _detachFoldHaptics = Haptics.instance.playTimeline(_fold, Haptics.foldStepCue());
    _fly = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
    _fly.addStatusListener((s) {
      if (s == AnimationStatus.completed) _complete();
    });
  }

  void _doFold() {
    if (_folded) return;
    _fold.forward().whenComplete(() => setState(() => _folded = true));
  }

  void _throw(DragEndDetails d) {
    if (!_folded || _fly.isAnimating || _finished) return;
    final v = d.velocity.pixelsPerSecond;
    if (v.distance < 300) return; // 약하면 무시
    _flyDir = v / v.distance;
    // 던지기 속도 → 비행 거리·햅틱 강도가 같은 v.distance에서 파생되도록.
    _flySpeed = ((v.distance - 300) / 2300).clamp(0.0, 1.0);
    Haptics.instance.impactBySpeed(v.distance); // 세게 던질수록 강하게
    _fly.forward();
  }

  void _complete() {
    if (_finished || !mounted) return;
    _finished = true;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => const CompleteScreen(afterglow: Text('🛩️', style: TextStyle(fontSize: 84))),
    ));
  }

  @override
  void dispose() {
    _detachFoldHaptics();
    _fold.dispose();
    _fly.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = SessionScope.of(context).text;
    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Stack(
            children: [
              Center(
                child: GestureDetector(
                  onPanEnd: _throw,
                  child: AnimatedBuilder(
                    animation: Listenable.merge([_fold, _flyCurve]),
                    builder: (context, _) {
                      final size = MediaQuery.of(context).size;
                      final t = _flyCurve.value; // 부드럽게 감속하는 글라이드
                      // 직선 성분: 빠르게 던질수록 멀리.
                      final dist = size.longestSide * (0.7 + _flySpeed * 0.7);
                      final base = _flyDir * dist * t;
                      // 약한 sin 흔들림 + 살짝 떠올랐다 내려가는 포물선(착지 시 안정).
                      final wobble = Offset(
                        sin(t * pi * 2) * 18 * (1 - t),
                        -sin(t * pi) * 40,
                      );
                      final flight = t;
                      final offset = base + wobble;
                      final angle = atan2(_flyDir.dy, _flyDir.dx);
                      return Transform.translate(
                        offset: offset,
                        child: Transform.rotate(
                          angle: _folded ? angle : 0,
                          child: Transform.scale(
                            scale: 1 - flight * 0.7,
                            child: Opacity(
                              opacity: (1 - flight).clamp(0.0, 1.0),
                              child: _folded
                                  ? const Text('🛩️', style: TextStyle(fontSize: 96))
                                  : Transform(
                                      alignment: Alignment.center,
                                      // 접히는 중: 가로로 좁아지는 연출
                                      transform: Matrix4.diagonal3Values(
                                          1 - _fold.value * 0.5, 1.0, 1.0),
                                      child: PaperCard(text: text, width: 240, height: 320),
                                    ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 44,
                child: Column(
                  children: [
                    if (!_folded)
                      FilledButton.icon(
                        onPressed: _doFold,
                        icon: const Icon(Icons.flight),
                        label: const Text('비행기로 접기'),
                        style: FilledButton.styleFrom(backgroundColor: AppColors.ballGlow),
                      )
                    else
                      const Text('손가락으로 휙 던져 날려 보내요',
                          style: TextStyle(color: Colors.white60)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
