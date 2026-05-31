import 'package:flutter/material.dart';

import '../models/ritual_type.dart';
import '../theme/app_colors.dart';

/// 해소 의식 선택 시트 (PRODUCT_SPEC 4.4, IA의 ReleaseSelect에 해당).
///
/// 카드 그리드에서 의식을 고르면 해당 [RitualType]을 반환한다. 닫으면 null.
/// 현재는 MVP 의식만 활성화하고, 2차/확장 의식은 비활성 카드로 보여준다.
Future<RitualType?> showRitualSheet(BuildContext context) {
  return showModalBottomSheet<RitualType>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (context) => const _RitualSheet(),
  );
}

class _RitualSheet extends StatelessWidget {
  const _RitualSheet();

  @override
  Widget build(BuildContext context) {
    final rituals = RitualType.values;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.cardTop, AppColors.cardBottom],
        ),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              '지금 내 감정에 맞는 방식을 선택해요',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w500,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 18),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.5,
              children: [
                for (final ritual in rituals)
                  _RitualCard(
                    ritual: ritual,
                    // MVP 의식만 선택 가능. 나머지는 곧 추가 예정.
                    enabled: ritual.availability == RitualAvailability.mvp,
                    onTap: () => Navigator.of(context).pop(ritual),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RitualCard extends StatelessWidget {
  const _RitualCard({
    required this.ritual,
    required this.enabled,
    required this.onTap,
  });

  final RitualType ritual;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Material(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // TODO(motion): 의식별 미니 프리뷰 애니메이션.
                Text(
                  ritual.label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  enabled ? ritual.matchedEmotion : '곧 추가돼요',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.8),
                    fontSize: 12,
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
