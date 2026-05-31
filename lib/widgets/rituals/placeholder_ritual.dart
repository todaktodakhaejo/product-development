import 'package:flutter/material.dart';

import '../../models/ritual_type.dart';
import 'ritual_stage.dart';

/// 2차/확장 의식의 임시 화면. 아직 전용 인터랙션이 없는 의식에 사용한다.
///
/// TODO(planner/motion/haptics): 각 의식이 구현되면 전용 위젯으로 교체하고
///                               [buildRitualInteraction] 분기에 등록한다.
class PlaceholderRitual extends StatelessWidget {
  const PlaceholderRitual({
    super.key,
    required this.type,
    required this.onComplete,
  });

  final RitualType type;
  final VoidCallback onComplete;

  @override
  Widget build(BuildContext context) {
    return RitualStage(
      title: type.label,
      hint: '이 의식은 곧 추가될 예정이에요',
      onComplete: onComplete,
    );
  }
}
