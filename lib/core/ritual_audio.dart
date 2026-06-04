import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// 해소 의식 효과음 재생기 (싱글턴).
///
/// 프로토타입(prototype-eight-bice.vercel.app)의 Web Audio 효과음을 **그대로** 옮긴다:
/// - 태우기  : `fire.mp3`     를 연소 동안 루프(volume 0.8). 점화 시작→정지.
/// - 파쇄기  : `shred.mp3`    를 분쇄 동안 루프(0.55) + 폭죽 시 `firework.mp3` 원샷(0.55).
/// - 날리기  : `paper.mp3`    를 접기/발사 순간 원샷(1.0).
/// - 보석함  : 합성 차임 `jewel_intake.wav`(투입) / `jewel_keep.wav`(간직) 원샷.
///   (원본은 Web Audio 합성음 → 동일 파라미터로 오프라인 렌더링한 wav)
///
/// 햅틱과 마찬가지로 "켜고 끄는" 얇은 파사드. 실패해도 의식 흐름을 막지 않도록
/// 모든 호출을 best-effort(예외 무시)로 감싼다.
class RitualAudio {
  RitualAudio._();
  static final RitualAudio instance = RitualAudio._();

  // 루프 채널(fire/shred — 의식 간 동시 재생 없음) + 원샷 2채널(firework·paper / jewel).
  final AudioPlayer _loop = AudioPlayer(playerId: 'ritual_loop');
  final AudioPlayer _shotA = AudioPlayer(playerId: 'ritual_shot_a');
  final AudioPlayer _shotB = AudioPlayer(playerId: 'ritual_shot_b');
  // 앰비언트 전용 채널(하늘 두둥실 — 루프 채널과 독립).
  final AudioPlayer _ambient = AudioPlayer(playerId: 'ritual_ambient');

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

  // ── 태우기 ───────────────────────────────────────────────────────────────
  /// 연소 시작 — fire.mp3 루프(volume 0.8). 점화 확정 시 호출.
  Future<void> startFire() => _safe(() async {
        await _loop.stop();
        await _loop.setReleaseMode(ReleaseMode.loop);
        await _loop.setVolume(0.8);
        await _loop.play(AssetSource('audio/fire.mp3'), volume: 0.8);
      });

  /// 연소 종료(전소) — fire 루프 정지.
  Future<void> stopFire() => _safe(() => _loop.stop());

  // ── 파쇄기 ───────────────────────────────────────────────────────────────
  /// 분쇄 시작 — shred.mp3 루프(volume 0.55). 종이 투입→분쇄 진입 시 호출.
  Future<void> startShred() => _safe(() async {
        await _loop.stop();
        await _loop.setReleaseMode(ReleaseMode.loop);
        await _loop.setVolume(0.55);
        await _loop.play(AssetSource('audio/shred.mp3'), volume: 0.55);
      });

  /// 분쇄 종료 — shred 루프 정지.
  Future<void> stopShred() => _safe(() => _loop.stop());

  /// 폭죽 — firework.mp3 원샷(volume 0.55). 폭죽 연쇄 정점마다 호출 가능.
  Future<void> firework() => _safe(() async {
        await _shotA.stop();
        await _shotA.setReleaseMode(ReleaseMode.release);
        await _shotA.play(AssetSource('audio/firework.mp3'), volume: 0.55);
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

  /// '하늘 두둥실' 포근한 앰비언트 루프 시작(volume 0.5). done 하늘 씬 진입 시 호출.
  Future<void> startSky() => _safe(() async {
        await _ambient.stop();
        await _ambient.setReleaseMode(ReleaseMode.loop);
        await _ambient.setVolume(0.5);
        await _ambient.play(AssetSource('audio/sky_float.wav'), volume: 0.5);
      });

  /// 하늘 앰비언트 정지('처음으로' 탭 등).
  Future<void> stopSky() => _safe(() => _ambient.stop());

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

  /// 화면 dispose 시 호출 — 잔여 루프/원샷 정지(다음 의식으로 새지 않게).
  Future<void> stopAll() => _safe(() async {
        await _loop.stop();
        await _shotA.stop();
        await _shotB.stop();
        await _ambient.stop();
      });
}
