/// 해소 의식의 종류 (docs/PRODUCT_SPEC.md 4.4).
///
/// ①~⑦은 "없애는" 의식, ⑧⑨는 "간직하는" 의식.
/// availability로 MVP/2차/확장을 구분해 단계적으로 구현한다.
enum RitualType {
  // MVP (필수)
  shred('파쇄기로 갈기', '분노 · 억울함', RitualKind.release, RitualAvailability.mvp),
  crumple('구겨서 던지기', '답답함', RitualKind.release, RitualAvailability.mvp),
  bonfire('모닥불에 태우기', '슬픔 · 후회', RitualKind.release, RitualAvailability.mvp),
  tear('종이 찢기', '짜증', RitualKind.release, RitualAvailability.mvp),

  // 2차
  shuffle('글자 뒤섞기', '혼란', RitualKind.release, RitualAvailability.secondary),
  unravel('엉킨 실 풀기', '미련', RitualKind.release, RitualAvailability.secondary),

  // 확장
  airplane('비행기 접어 날리기', '훌훌 털기', RitualKind.release, RitualAvailability.extended),
  jewelry('보석함에 넣기', '소중히 간직', RitualKind.keep, RitualAvailability.extended),
  savings('저금 · 골드바', '성취 · 설렘', RitualKind.keep, RitualAvailability.extended);

  const RitualType(
    this.label,
    this.matchedEmotion,
    this.kind,
    this.availability,
  );

  /// 카드에 표시되는 의식 이름.
  final String label;

  /// 대응 감정 (카드 보조 표시).
  final String matchedEmotion;

  /// 없애기 / 간직하기.
  final RitualKind kind;

  /// 구현 우선순위.
  final RitualAvailability availability;

  /// 마무리 화면 메시지 (간직 의식은 다른 카피).
  String get closingMessage =>
      kind == RitualKind.keep ? '잘 담아뒀어요' : '다 보냈어요';
}

/// 의식의 성격 — 감정을 없애는가, 간직하는가.
enum RitualKind { release, keep }

/// 구현 단계.
enum RitualAvailability { mvp, secondary, extended }
