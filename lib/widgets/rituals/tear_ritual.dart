import 'package:flutter/material.dart';

import 'ritual_stage.dart';

/// ④ 종이 찢기 — 짜증 (PRODUCT_SPEC 4.4 ④).
///
/// TODO(motion): 두 손가락을 벌려 찢기(여러 번 가능), 위로 스와이프하면
///               조각들이 흩어져 사라짐.
/// TODO(haptics): 찢는 순간마다 tear 임팩트 햅틱.
/// TODO(haptics): "찌익" 사운드(SoundKey.tear).
class TearRitual extends StatelessWidget {
  const TearRitual({super.key, required this.onComplete});

  final VoidCallback onComplete;

  @override
  Widget build(BuildContext context) {
    return RitualStage(
      title: '종이 찢기',
      hint: '두 손가락을 벌려 찢어요',
      onComplete: onComplete,
    );
  }
}
