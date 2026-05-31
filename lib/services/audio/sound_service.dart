/// ASMR 사운드 키 (제스처/의식별 시그니처 1개). assets/sounds에 번들 예정.
///
/// TODO(haptics): 실제 에셋 추가 후 키→파일 매핑을 구현체에서 연결.
enum SoundKey {
  tap, // 통
  rub, // 사락사락
  shred, // 드르륵 (파쇄)
  burn, // 화르륵 (모닥불)
  tear, // 찌익 (찢기)
  crumple, // 구김
}

/// ASMR 사운드 재생 추상화. 작고 가까운 질감음(PRODUCT_SPEC 2.5).
///
/// 독립 성립 원칙: 사운드 없이 햅틱만으로도 경험이 성립해야 하므로,
/// 본 추상화는 햅틱과 강결합하지 않는다.
abstract class SoundService {
  Future<void> play(SoundKey key, {double volume = 1.0});
  Future<void> stop();
}

/// 사운드 미연결 상태의 폴백 — 무음(no-op).
///
/// TODO(haptics): audioplayers/just_audio로 실제 재생을 구현한
/// AudioPlayersSoundService를 추가한다.
class NoopSoundService implements SoundService {
  @override
  Future<void> play(SoundKey key, {double volume = 1.0}) async {}

  @override
  Future<void> stop() async {}
}
