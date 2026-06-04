import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as ja;

/// 해소 의식 효과음 재생기 (싱글턴).
///
/// 프로토타입(prototype-eight-bice.vercel.app)의 Web Audio 효과음을 **그대로** 옮긴다:
/// - 태우기  : `fire.mp3`     를 연소 동안 루프(volume 1.0) → 전소 후 `crackle.wav`
///             잔불 타닥타닥 여운(갱리스 루프). 점화→정지/여운.
/// - 파쇄기  : `shred.mp3`    를 분쇄 동안 루프(1.0) + 폭죽 타이밍마다 `firework.mp3`
///             원샷(2보이스 라운드로빈, 0.85).
/// - 날리기  : `paper.mp3`    접기 / `whoosh.wav` 발사 / `sky_float.wav` 하늘 앰비언트.
/// - 보석함  : 합성 차임 `jewel_intake.wav`(투입) / `jewel_keep.wav`(간직) 원샷.
///   (보석함·whoosh·sky·crackle은 원본 합성/부재 → 동일 파라미터로 오프라인 렌더 wav)
///
/// 끊김 없이 이어져야 하는 루프(하늘 앰비언트·잔불)는 audioplayers의 iOS 루프 갭을
/// 피하려 `just_audio`(갱리스)를 쓴다. 그 외 단발/노이즈 루프는 audioplayers.
///
/// 햅틱과 마찬가지로 "켜고 끄는" 얇은 파사드. 실패해도 의식 흐름을 막지 않도록
/// 모든 호출을 best-effort(예외 무시)로 감싼다.
class RitualAudio {
  RitualAudio._();
  static final RitualAudio instance = RitualAudio._();

  // 루프 채널(fire/shred — 의식 간 동시 재생 없음) + 원샷 2채널.
  final AudioPlayer _loop = AudioPlayer(playerId: 'ritual_loop');
  final AudioPlayer _shotA = AudioPlayer(playerId: 'ritual_shot_a');
  final AudioPlayer _shotB = AudioPlayer(playerId: 'ritual_shot_b');
  // 끊김 없는 루프 전용(하늘 앰비언트 — audioplayers는 iOS 루프 갭 발생).
  final ja.AudioPlayer _gapless = ja.AudioPlayer();
  // 잔불 타닥타닥(audioplayers 루프 — crackle은 경계가 조용해 갭이 안 들림).
  // 태우기 경로가 just_audio를 건드리지 않게 해, 완료 시점 첫 init 멈칫을 회피.
  final AudioPlayer _emberLoop = AudioPlayer(playerId: 'ritual_ember');
  // 폭죽 원샷 2보이스 라운드로빈(빠른 연속 팡팡이 서로 끊지 않도록).
  bool _fwToggle = false;

  bool _booted = false;

  /// iOS 무음 스위치와 무관하게 효과음이 들리도록 playback 컨텍스트로 1회 설정.
  Future<void> _boot() async {
    if (_booted) return;
    _booted = true;
    try {
      await AudioPlayer.global.setAudioContext(
        AudioContext(
          iOS: AudioContextIOS(
            category: AVAudioSessionCategory.playback,
            options: const {AVAudioSessionOptions.mixWithOthers},
          ),
          android: const AudioContextAndroid(
            isSpeakerphoneOn: false,
            contentType: AndroidContentType.sonification,
            usageType: AndroidUsageType.assistanceSonification,
            audioFocus: AndroidAudioFocus.gainTransientMayDuck,
          ),
        ),
      );
    } catch (e) {
      debugPrint('RitualAudio boot 실패(무시): $e');
    }
  }

  Future<void> _safe(Future<void> Function() body) async {
    try {
      await _boot();
      await body();
    } catch (e) {
      debugPrint('RitualAudio 재생 실패(무시): $e');
    }
  }

  /// just_audio(하늘 앰비언트) 첫 초기화(디코드·세션 활성) 비용을 앱 시작 시 미리
  /// 치른다 — 의식 도중 앰비언트가 처음 시작될 때 시뮬레이터에서 프레임이 멈칫
  /// (터치해야 진행)하는 것을 방지. best-effort.
  Future<void> warmUp() => _safe(() async {
        await _gapless.setVolume(0);
        await _gapless.setAudioSource(
          ja.AudioSource.asset('assets/audio/sky_float.wav'),
        );
        await _gapless.play();
        await _gapless.pause();
        await _gapless.seek(Duration.zero);
        await _gapless.stop();
      });

  /// 끊김 없는 무한 루프(just_audio LoopingAudioSource로 갱리스 보장).
  Future<void> _startGapless(String assetPath, double volume) => _safe(() async {
        await _gapless.stop();
        await _gapless.setVolume(volume);
        // count는 '시퀀스 길이'라 너무 크면(예: 1<<20) 시퀀스 생성이 메인 스레드를
        // 멈춰 화면이 프리징된다. 세션 한 번에 충분한 길이(4~8s × 1000 ≈ 1~2시간).
        await _gapless.setAudioSource(
          ja.LoopingAudioSource(
            count: 1000,
            child: ja.AudioSource.asset(assetPath),
          ),
        );
        await _gapless.play();
      });

  // ── 태우기 ───────────────────────────────────────────────────────────────
  /// 연소 시작 — fire.mp3 루프(volume 1.0, 강하게). 점화 확정 시 호출.
  Future<void> startFire() => _safe(() async {
        await _loop.stop();
        await _loop.setReleaseMode(ReleaseMode.loop);
        await _loop.setVolume(1.0);
        await _loop.play(AssetSource('audio/fire.mp3'), volume: 1.0);
      });

  /// 연소 종료(전소) — fire 루프 정지.
  Future<void> stopFire() => _safe(() => _loop.stop());

  /// 전소 후 잔불 타닥타닥 여운 — crackle.wav 루프(volume 0.7, audioplayers).
  /// '처음으로' 탭/dispose까지 은은히 남는다.
  Future<void> startEmberCrackle() => _safe(() async {
        await _emberLoop.stop();
        await _emberLoop.setReleaseMode(ReleaseMode.loop);
        await _emberLoop.setVolume(0.7);
        await _emberLoop.play(AssetSource('audio/crackle.wav'), volume: 0.7);
      });

  /// 잔불 여운 정지.
  Future<void> stopEmberCrackle() => _safe(() => _emberLoop.stop());

  // ── 파쇄기 ───────────────────────────────────────────────────────────────
  /// 분쇄 시작 — shred.mp3 루프(volume 1.0, 강하게). 종이 투입 순간 호출.
  Future<void> startShred() => _safe(() async {
        await _loop.stop();
        await _loop.setReleaseMode(ReleaseMode.loop);
        await _loop.setVolume(1.0);
        await _loop.play(AssetSource('audio/shred.mp3'), volume: 1.0);
      });

  /// 분쇄 종료 — shred 루프 정지.
  Future<void> stopShred() => _safe(() => _loop.stop());

  /// 폭죽 — firework.mp3 원샷(volume 0.85). 폭죽이 터지는 매 타이밍마다 호출.
  /// 2보이스 라운드로빈으로 빠른 연속('팡팡')이 서로 끊기지 않게 한다.
  Future<void> firework() => _safe(() async {
        _fwToggle = !_fwToggle;
        final p = _fwToggle ? _shotA : _shotB;
        await p.stop();
        await p.setReleaseMode(ReleaseMode.release);
        await p.play(AssetSource('audio/firework.mp3'), volume: 0.85);
      });

  // ── 날리기 ───────────────────────────────────────────────────────────────
  /// 종이 접히는 소리 — paper.mp3 원샷(volume 1.0). 접기 시작 시 호출.
  Future<void> paper() => _safe(() async {
        await _shotA.stop();
        await _shotA.setReleaseMode(ReleaseMode.release);
        await _shotA.play(AssetSource('audio/paper.mp3'), volume: 1.0);
      });

  /// 발사 — whoosh.wav 원샷(바람 가로지르는 소리). 종이비행기를 놓아 날릴 때 호출.
  Future<void> whoosh() => _safe(() async {
        await _shotA.stop();
        await _shotA.setReleaseMode(ReleaseMode.release);
        await _shotA.play(AssetSource('audio/whoosh.wav'), volume: 0.9);
      });

  /// 일회성 채널(접기·발사음) 즉시 정지. 접기 완료~발사 전 무음 구간 보장에 사용.
  Future<void> stopShot() => _safe(() => _shotA.stop());

  /// '하늘 두둥실' 포근한 앰비언트 갱리스 루프(volume 0.5). done 하늘 씬 진입 시 호출.
  Future<void> startSky() => _startGapless('assets/audio/sky_float.wav', 0.5);

  /// 하늘 앰비언트 정지('처음으로' 탭 등).
  Future<void> stopSky() => _safe(() => _gapless.stop());

  // ── 보석함 ───────────────────────────────────────────────────────────────
  /// 투입 차임 — jewel_intake.wav 원샷(사인 760+1140Hz 2음).
  Future<void> jewelIntake() => _safe(() async {
        await _shotB.stop();
        await _shotB.setReleaseMode(ReleaseMode.release);
        await _shotB.play(AssetSource('audio/jewel_intake.wav'));
      });

  /// 간직 반짝임 — jewel_keep.wav 원샷(트라이앵글 8음 상승 아르페지오).
  Future<void> jewelKeep() => _safe(() async {
        await _shotB.stop();
        await _shotB.setReleaseMode(ReleaseMode.release);
        await _shotB.play(AssetSource('audio/jewel_keep.wav'));
      });

  /// 화면 dispose 시 호출 — 잔여 루프/원샷/앰비언트 모두 정지(다음 의식으로 안 샘).
  Future<void> stopAll() => _safe(() async {
        await _loop.stop();
        await _shotA.stop();
        await _shotB.stop();
        await _emberLoop.stop();
        await _gapless.stop();
      });
}
