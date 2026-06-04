import 'dart:async';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// 해소 의식 효과음 재생기 (싱글턴).
///
/// 프로토타입(prototype-eight-bice.vercel.app)의 Web Audio 효과음을 **그대로** 옮긴다:
/// - 태우기  : `fire.mp3` 연소 루프(1.0) → 전소 후 `crackle.wav` 잔불 여운 루프.
/// - 파쇄기  : `shred.mp3` 분쇄 루프(1.0) + 폭죽 타이밍마다 `firework.mp3` 원샷(0.85).
/// - 날리기  : `paper.mp3` 접기 / `whoosh.wav` 발사 / `sky_float.wav` 하늘 앰비언트.
/// - 보석함  : 합성 차임 `jewel_intake.wav`(투입) / `jewel_keep.wav`(간직) 원샷.
///
/// **오디오는 audioplayers 단일 플러그인만 사용한다.** (just_audio는 iOS 시뮬레이터에서
/// 버퍼링·프레임 멈칫을 유발해 제거.) 끊김 없이 이어져야 하는 하늘 앰비언트는
/// audioplayers의 루프 갭을 피하려 **두 플레이어 크로스페이드 더블버퍼**로 무한 루프한다.
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
  // 잔불 타닥타닥(단순 루프 — crackle은 경계가 조용해 갭이 안 들림).
  final AudioPlayer _emberLoop = AudioPlayer(playerId: 'ritual_ember');
  // 하늘 앰비언트 더블버퍼(끊김 없는 루프 — 두 플레이어를 크로스페이드).
  final AudioPlayer _skyA = AudioPlayer(playerId: 'ritual_sky_a');
  final AudioPlayer _skyB = AudioPlayer(playerId: 'ritual_sky_b');
  // 폭죽 원샷 2보이스 라운드로빈(빠른 연속 팡팡이 서로 끊지 않도록).
  bool _fwToggle = false;

  // ── 하늘 앰비언트 더블버퍼 상태 ──────────────────────────────────────────
  // sky_float.wav 길이(30s, seamless). 클립이 길어 전환(크로스페이드)이 드물다.
  static const Duration _kSkyClip = Duration(milliseconds: 30000);
  // 다음 클립을 미리 시작해 겹치는 시간(전환 타이밍 오차 흡수 + 크로스페이드 구간).
  static const Duration _kSkyOverlap = Duration(milliseconds: 900);
  static const double _kSkyVolume = 0.5;
  bool _skyRunning = false;
  bool _skyUseA = true; // 현재 들리는 쪽.
  Timer? _skySwap; // 다음 전환 예약.
  Timer? _skyXfade; // 전환 시 크로스페이드 램프.
  Timer? _skyFadeIn; // 최초 진입 페이드인(그라데이션).

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
  /// 연소 시작 — fire.mp3 루프(volume 1.0, 강하게). 점화 확정 시 호출.
  Future<void> startFire() => _safe(() async {
        await _loop.stop();
        await _loop.setReleaseMode(ReleaseMode.loop);
        await _loop.setVolume(1.0);
        await _loop.play(AssetSource('audio/fire.mp3'), volume: 1.0);
      });

  /// 연소 종료(전소) — fire 루프 정지.
  Future<void> stopFire() => _safe(() => _loop.stop());

  /// 전소 후 잔불 타닥타닥 여운 — crackle.wav 루프(volume 0.7).
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

  /// '하늘 두둥실' 포근한 앰비언트 — 두 플레이어 크로스페이드 더블버퍼로 끊김 없이
  /// 무한 루프. 비행음(whoosh)이 끝나는 즈음 호출하면 볼륨 0→0.5 페이드인(그라데이션)
  /// 으로 자연스럽게 이어진다. 이미 돌고 있으면(중복 호출) 무시한다.
  Future<void> startSky() => _safe(() async {
        if (_skyRunning) return;
        _skyRunning = true;
        _skyUseA = true;
        await _skyA.setReleaseMode(ReleaseMode.stop);
        await _skyB.setReleaseMode(ReleaseMode.stop);
        await _skyA.setVolume(0);
        await _skyA.play(AssetSource('audio/sky_float.wav'), volume: 0);
        // 진입 그라데이션(볼륨 0 → _kSkyVolume).
        _ramp(_skyFadeIn, _skyA, 0, _kSkyVolume,
            const Duration(milliseconds: 1400), (t) => _skyFadeIn = t);
        _scheduleSkySwap();
      });

  /// 하늘 앰비언트 정지('처음으로' 탭 등) — 타이머·두 플레이어 모두 정리.
  Future<void> stopSky() => _safe(_stopSkyInternal);

  Future<void> _stopSkyInternal() async {
    _skyRunning = false;
    _skySwap?.cancel();
    _skyXfade?.cancel();
    _skyFadeIn?.cancel();
    await _skyA.stop();
    await _skyB.stop();
  }

  // 클립이 끝나기 직전(overlap 전)에 반대편 플레이어로 전환 예약.
  void _scheduleSkySwap() {
    _skySwap?.cancel();
    _skySwap = Timer(_kSkyClip - _kSkyOverlap, () {
      if (!_skyRunning) return;
      _swapSky();
    });
  }

  // 현재 플레이어가 끝나기 전에 반대편을 시작하고 overlap 동안 크로스페이드.
  Future<void> _swapSky() async {
    if (!_skyRunning) return;
    final out = _skyUseA ? _skyA : _skyB;
    final inn = _skyUseA ? _skyB : _skyA;
    try {
      await inn.setReleaseMode(ReleaseMode.stop);
      await inn.setVolume(0);
      await inn.play(AssetSource('audio/sky_float.wav'), volume: 0);
    } catch (e) {
      debugPrint('RitualAudio sky swap 실패(무시): $e');
    }
    _skyUseA = !_skyUseA;
    // 등파워 크로스페이드: out ↓, inn ↑ (overlap 동안). out은 클립 끝나며 자연 종료.
    _crossfadeSky(out, inn);
    _scheduleSkySwap();
  }

  void _crossfadeSky(AudioPlayer out, AudioPlayer inn) {
    _skyXfade?.cancel();
    const stepMs = 50; // 드물게(클립당 1회) + 적은 스텝 → 잰크 위험 최소.
    final steps = (_kSkyOverlap.inMilliseconds / stepMs).round();
    var i = 0;
    _skyXfade = Timer.periodic(const Duration(milliseconds: stepMs), (t) {
      if (!_skyRunning) {
        t.cancel();
        return;
      }
      i++;
      final x = (i / steps).clamp(0.0, 1.0);
      out.setVolume(_kSkyVolume * cos(x * pi / 2)); // 등파워(합≈일정)
      inn.setVolume(_kSkyVolume * sin(x * pi / 2));
      if (i >= steps) t.cancel();
    });
  }

  // 단일 플레이어 볼륨 램프(페이드). 진행 중 타이머는 setter로 보관해 취소 가능.
  void _ramp(Timer? slot, AudioPlayer p, double from, double to,
      Duration dur, void Function(Timer?) store) {
    slot?.cancel();
    const stepMs = 50;
    final steps = (dur.inMilliseconds / stepMs).round().clamp(1, 1000);
    var i = 0;
    final t = Timer.periodic(const Duration(milliseconds: stepMs), (timer) {
      i++;
      final x = (i / steps).clamp(0.0, 1.0);
      p.setVolume(from + (to - from) * x);
      if (i >= steps) timer.cancel();
    });
    store(t);
  }

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
        _skyRunning = false;
        _skySwap?.cancel();
        _skyXfade?.cancel();
        _skyFadeIn?.cancel();
        await _loop.stop();
        await _shotA.stop();
        await _shotB.stop();
        await _emberLoop.stop();
        await _skyA.stop();
        await _skyB.stop();
      });
}
