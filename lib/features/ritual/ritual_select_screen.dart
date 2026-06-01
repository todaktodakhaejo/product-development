import 'package:flutter/material.dart';

import '../../core/haptics.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';
import 'rituals/burn_ritual_screen.dart';
import 'rituals/jewelry_box_ritual_screen.dart';
import 'rituals/paper_plane_ritual_screen.dart';
import 'rituals/shredder_ritual_screen.dart';

/// 5단계 의식 선택. 우선순위 '필수' 4종.
class RitualSelectScreen extends StatelessWidget {
  const RitualSelectScreen({super.key});

  static const _icons = {
    Ritual.burn: '🔥',
    Ritual.shredder: '🎉',
    Ritual.paperPlane: '🛩️',
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
                  child: GridView(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 16,
                      crossAxisSpacing: 16,
                      mainAxisExtent: 172, // 카드 높이 고정: 설명 2줄 온전히 표시
                    ),
                    children: [
                      for (final r in Ritual.values)
                        _RitualCard(
                          emoji: _icons[r]!,
                          ritual: r,
                          onTap: () => _select(context, r),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                const _ComingSoonTile(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 2차 스펙 의식들이 곧 추가됨을 알리는 비활성 예고 칸 (터치 불가, 흐림 처리).
class _ComingSoonTile extends StatelessWidget {
  const _ComingSoonTile();

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.7,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white12),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('✨', style: TextStyle(fontSize: 15)),
            SizedBox(width: 8),
            Text(
              '더 많은 방법들이 기다리고 있어요',
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _RitualCard extends StatelessWidget {
  const _RitualCard(
      {required this.emoji, required this.ritual, required this.onTap});
  final String emoji;
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
            Text(emoji, style: const TextStyle(fontSize: 40)),
            const Spacer(),
            Row(
              children: [
                Flexible(
                  child: Text(ritual.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 6),
                if (keep)
                  const Icon(Icons.bookmark, size: 14, color: Colors.white38),
              ],
            ),
            const SizedBox(height: 4),
            Flexible(
              child: Text(ritual.tagline,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white54, fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }
}
