import 'package:flutter/material.dart';

import '../../core/haptics.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';
import 'rituals/burn_ritual_screen.dart';
import 'rituals/jewelry_box_ritual_screen.dart';
import 'rituals/paper_plane_ritual_screen.dart';
import 'rituals/shredder_ritual_screen.dart';
import 'widgets/paper_plane_glyph.dart';

/// 5단계 의식 선택. 우선순위 '필수' 4종.
class RitualSelectScreen extends StatelessWidget {
  const RitualSelectScreen({super.key});

  // paperPlane은 이모지 대신 CustomPaint 글리프로 렌더한다(아래 _RitualCard 분기).
  // 따라서 _icons에는 paperPlane 항목을 두지 않는다(이모지 0).
  static const _icons = {
    Ritual.burn: '🔥',
    Ritual.shredder: '🎉',
    Ritual.jewelryBox: '💎',
  };

  Widget _screenFor(Ritual r) {
    switch (r) {
      case Ritual.burn:
        return const BurnRitualScreen();
      case Ritual.shredder:
        return const ShredderRitualScreen();
      case Ritual.paperPlane:
        return const PaperPlaneRitualScreen();
      case Ritual.jewelryBox:
        return const JewelryBoxRitualScreen();
    }
  }

  void _select(BuildContext context, Ritual r) {
    SessionScope.of(context).chooseRitual(r);
    Haptics.instance.fire(HapticLevel.selection);
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => _screenFor(r)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 8),
                const Text(
                  '어떻게 보낼까요?',
                  style:
                      TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                const Text(
                  '마음에 드는 방식으로 흘려보내거나 간직하세요.',
                  style: TextStyle(color: Colors.white60),
                ),
                const SizedBox(height: 24),
                Expanded(
                  child: GridView.count(
                    crossAxisCount: 2,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 16,
                    childAspectRatio: 0.95,
                    children: [
                      for (final r in Ritual.values)
                        _RitualCard(
                          emoji: _icons[r], // paperPlane은 null(글리프 분기)
                          ritual: r,
                          onTap: () => _select(context, r),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RitualCard extends StatelessWidget {
  const _RitualCard(
      {required this.emoji, required this.ritual, required this.onTap});
  final String? emoji; // paperPlane은 글리프라 null
  final Ritual ritual;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final keep = ritual.kind == RitualKind.keep;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 종이비행기만 직접 그린 다트 글리프(이모지 아님), 나머지는 이모지.
            if (ritual == Ritual.paperPlane)
              const PaperPlaneGlyph(size: 44)
            else
              Text(emoji!, style: const TextStyle(fontSize: 44)),
            const Spacer(),
            Row(
              children: [
                Text(ritual.label,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w600)),
                const SizedBox(width: 6),
                if (keep)
                  const Icon(Icons.bookmark, size: 14, color: Colors.white38),
              ],
            ),
            const SizedBox(height: 4),
            Text(ritual.tagline,
                style: const TextStyle(color: Colors.white54, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
