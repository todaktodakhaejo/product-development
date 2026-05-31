import 'package:flutter/material.dart';

import 'ritual_stage.dart';

/// ① 파쇄기로 갈기 — 분노·억울함 (PRODUCT_SPEC 4.4 ①).
///
/// TODO(motion): 종이를 위→아래로 밀어넣기(잡았다 놓기 가능), 갈린 조각이 쌓이다
///               폭죽처럼 터지며(burst) 페이드아웃.
/// TODO(haptics): 들어가는 순간 진동 + 갈리는 동안 shredGrind 연속 진동.
/// TODO(haptics): "드르륵" 시그니처 사운드(SoundKey.shred).
class ShredderRitual extends StatelessWidget {
  const ShredderRitual({super.key, required this.onComplete});

  final VoidCallback onComplete;

  @override
  Widget build(BuildContext context) {
    return RitualStage(
      title: '파쇄기로 갈기',
      hint: '종이를 위에서 아래로 밀어 넣어요',
      onComplete: onComplete,
    );
  }
}
