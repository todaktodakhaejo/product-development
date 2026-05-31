import 'package:flutter/material.dart';

import 'ritual_stage.dart';

/// ② 구겨서 던지기 — 답답함 (PRODUCT_SPEC 4.4 ②).
///
/// TODO(motion): 두 손가락을 모아 종이를 구김(세게 모을수록 더 작은 공),
///               휘두르거나 스와이프로 던져 날림.
/// TODO(haptics): 구기는 동안 가변 진동, 던지는 순간 release 햅틱(burst).
/// TODO(haptics): 구김/던짐 사운드(SoundKey.crumple).
class CrumpleRitual extends StatelessWidget {
  const CrumpleRitual({super.key, required this.onComplete});

  final VoidCallback onComplete;

  @override
  Widget build(BuildContext context) {
    return RitualStage(
      title: '구겨서 던지기',
      hint: '종이를 모아 구긴 뒤 던져요',
      onComplete: onComplete,
    );
  }
}
