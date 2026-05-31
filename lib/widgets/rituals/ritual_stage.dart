import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// 의식 수행 화면의 공통 골격 (placeholder).
///
/// 각 의식 위젯은 이 골격 위에 전용 인터랙션을 구현한다. 지금은 안내 카피와
/// "완료" 버튼만 제공해 플로우가 끝까지 흐르게 한다.
/// TODO(motion/haptics): [child] 자리에 의식별 인터랙션(드래그/제스처/파티클 등)을 넣고,
///                       완료 조건이 충족되면 [onComplete]를 호출하도록 교체.
class RitualStage extends StatelessWidget {
  const RitualStage({
    super.key,
    required this.title,
    required this.hint,
    required this.onComplete,
    this.child,
    this.glowColor,
  });

  /// 의식 이름.
  final String title;

  /// 수행 방법 안내 카피.
  final String hint;

  /// 의식 완료 콜백.
  final VoidCallback onComplete;

  /// 의식별 인터랙션 위젯(미구현 시 안내 placeholder 표시).
  final Widget? child;

  /// 의식별 강조색(배경 글로우).
  final Color? glowColor;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 24),
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(hint, style: Theme.of(context).textTheme.bodyMedium),
        Expanded(
          child: Center(
            child: child ??
                _Placeholder(glowColor: glowColor),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 28),
          child: TextButton(
            onPressed: onComplete,
            child: Text(
              '완료',
              style: TextStyle(
                color: glowColor ?? AppColors.buttonPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({this.glowColor});

  final Color? glowColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 200,
      height: 200,
      decoration: BoxDecoration(
        color: (glowColor ?? AppColors.glow).withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(24),
      ),
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          '여기에 의식 인터랙션이\n들어갈 자리예요',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}
