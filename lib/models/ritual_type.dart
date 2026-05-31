/// 해소 의식의 종류 (docs/PRODUCT_SPEC.md 4.4).
///
/// ①~⑦은 "없애는" 의식, ⑧⑨는 "간직하는" 의식.
/// availability로 MVP/2차/확장을 구분해 단계적으로 구현한다.
///
/// 주의: 의식은 특정 감정에 고정되지 않는다. 사용자가 자유롭게 선택하며,
/// UI에 감정을 라벨로 노출하지 않는다([hint]는 동작 설명일 뿐).
enum RitualType {
  // MVP (필수)
  shred('파쇄기로 갈기', '잘게 갈아 날리기', RitualKind.release, RitualAvailability.mvp),
  crumple('구겨서 던지기', '구겨서 멀리 던지기', RitualKind.release, RitualAvailability.mvp),
  bonfire('모닥불에 태우기', '천천히 태워 보내기', RitualKind.release, RitualAvailability.mvp),
  tear('종이 찢기', '여러 번 찢어 흩기', RitualKind.release, RitualAvailability.mvp),

  // 2차
  shuffle('글자 뒤섞기', '흔들어 부수기', RitualKind.release, RitualAvailability.secondary),
  unravel('엉킨 실 풀기', '매듭 하나씩 풀기', RitualKind.release, RitualAvailability.secondary),

  // 확장
  airplane('비행기 접어 날리기', '접어서 멀리 날리기', RitualKind.release, RitualAvailability.extended),
  jewelry('보석함에 넣기', '소중히 담아두기', RitualKind.keep, RitualAvailability.extended),
  savings('저금 · 골드바', '차곡차곡 모으기', RitualKind.keep, RitualAvailability.extended);

  const RitualType(
    this.label,
    this.hint,
    this.kind,
    this.availability,
  );

  /// 카드에 표시되는 의식 이름.
  final String label;

  /// 동작 설명 (카드 보조 표시). 감정이 아니라 "무엇을 하는지"를 담는다.
  final String hint;

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
