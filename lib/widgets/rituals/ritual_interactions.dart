import 'package:flutter/material.dart';

import '../../models/ritual_type.dart';
import 'bonfire_ritual.dart';
import 'crumple_ritual.dart';
import 'placeholder_ritual.dart';
import 'shredder_ritual.dart';
import 'tear_ritual.dart';

/// 선택된 [RitualType]에 맞는 의식 인터랙션 위젯을 만든다.
///
/// 새 의식을 구현하면 전용 위젯을 만들고 이 분기에 등록한다.
Widget buildRitualInteraction(
  RitualType type, {
  required VoidCallback onComplete,
}) {
  switch (type) {
    case RitualType.shred:
      return ShredderRitual(onComplete: onComplete);
    case RitualType.crumple:
      return CrumpleRitual(onComplete: onComplete);
    case RitualType.bonfire:
      return BonfireRitual(onComplete: onComplete);
    case RitualType.tear:
      return TearRitual(onComplete: onComplete);
    case RitualType.shuffle:
    case RitualType.unravel:
    case RitualType.airplane:
    case RitualType.jewelry:
    case RitualType.savings:
      return PlaceholderRitual(type: type, onComplete: onComplete);
  }
}
