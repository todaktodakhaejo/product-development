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
    Ritual.shredder: '📄',
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
                  '마음 가는 방식으로 골라보세요.',
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
                      mainAxisExtent: 210, // 카드 높이 고정: 설명 2줄 + 여유
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

/// 줄바꿈 금지 문자(word-joiner, U+2060).
final String _wordJoiner = String.fromCharCode(0x2060);

/// 한글이 글자 단위로 끊기지 않고 띄어쓰기(어절)에서만 줄바꿈되도록,
/// 각 단어의 글자 사이에 word-joiner를 넣어 단어를 통째로 묶는다.
String _wrapByWord(String text) =>
    text.split(' ').map((w) => w.split('').join(_wordJoiner)).join(' ');

class _RitualCard extends StatefulWidget {
  const _RitualCard(
      {required this.emoji, required this.ritual, required this.onTap});
  final String emoji;
  final Ritual ritual;
  final VoidCallback onTap;

  @override
  State<_RitualCard> createState() => _RitualCardState();
}

class _RitualCardState extends State<_RitualCard> {
  bool _pressed = false;

  void _setPressed(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  /// 흰색 반전 피드백을 잠깐 보여준 뒤 다음 화면으로 넘어간다.
  Future<void> _handleTap() async {
    _setPressed(true);
    await Future<void>.delayed(const Duration(milliseconds: 160));
    if (!mounted) return;
    widget.onTap();
    _setPressed(false);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: _pressed ? 0.95 : 1.0,
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOut,
      child: InkWell(
        onTap: _handleTap,
        onTapDown: (_) => _setPressed(true),
        onTapCancel: () => _setPressed(false),
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOut,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            // 누르면 흰 카드로 반전 → 선택이 시각적으로 또렷하게.
            color: _pressed ? Colors.white : Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: _pressed ? Colors.transparent : Colors.white12),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.emoji, style: const TextStyle(fontSize: 40)),
              const SizedBox(height: 12),
              Text(widget.ritual.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: _pressed ? AppColors.ink : Colors.white)),
              const SizedBox(height: 4),
              Text(_wrapByWord(widget.ritual.tagline),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: _pressed ? Colors.black54 : Colors.white54,
                      fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}
