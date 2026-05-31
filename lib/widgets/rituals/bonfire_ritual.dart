import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import 'ritual_stage.dart';

/// ③ 모닥불에 태우기 — 슬픔·후회 (PRODUCT_SPEC 4.4 ③).
///
/// TODO(motion): 종이를 천천히 드래그해 불 위에 놓으면 끝부터 아래→위로
///               천천히 타들어감(10~15s), 재가 되어 사라짐.
/// TODO(haptics): 연소 진행에 맞춰 아래→위 방향감의 연속 진동.
/// TODO(haptics): "화르륵" 사운드(SoundKey.burn).
class BonfireRitual extends StatelessWidget {
  const BonfireRitual({super.key, required this.onComplete});

  final VoidCallback onComplete;

  @override
  Widget build(BuildContext context) {
    return RitualStage(
      title: '모닥불에 태우기',
      hint: '종이를 불 위에 천천히 올려두세요',
      glowColor: AppColors.accentFireWarm,
      onComplete: onComplete,
    );
  }
}
