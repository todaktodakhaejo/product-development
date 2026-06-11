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
  // _loop 수동 반복 상태: 이 기기에서 mp3를 ReleaseMode.loop로 재생하면 첫 재생부터
  // 무음이 되는 버그(2026-06-12 실기기, fire/shred 무음)를 회피한다. release 모드로
  // 재생하고 onPlayerComplete에서 손수 다시 이어 "수동 루프"를 만든다(폭죽이 release
  // mp3로 정상 재생되는 검증된 경로와 동일 — loop 모드만 피하면 소리가 난다).
  String? _loopAsset; // 현재 반복 중인 에셋 경로(null이면 정지)
  double _loopVol = 1.0;
  StreamSubscription<void>? _loopCompleteSub;
  final AudioPlayer _shotA = AudioPlayer(playerId: 'ritual_shot_a');
  final AudioPlayer _shotB = AudioPlayer(playerId: 'ritual_shot_b');
  // 잔불 타닥타닥(단순 루프 — crackle은 경계가 조용해 갭이 안 들림).
  final AudioPlayer _emberLoop = AudioPlayer(playerId: 'ritual_ember');
  // 하늘 앰비언트 더블버퍼(끊김 없는 루프 — 두 플레이어를 크로스페이드).
  final AudioPlayer _skyA = AudioPlayer(playerId: 'ritual_sky_a');
  final AudioPlayer _skyB = AudioPlayer(playerId: 'ritual_sky_b');
  // 폭죽 원샷 보이스 풀(채널 스틸링 방지) — 피날레는 3초간 폭죽음을 빠르게 여러 번
  // 호출하는데(가장 빽빽한 1.4초 창에 7발) 보이스가 부족하면 앞 소리가 잘렸다(사용자
  // 피드백) → 8보이스 라운드로빈으로 동시 폭죽이 서로 안 끊기고 모두 끝까지 울리게 한다
  // (게임엔진 멀티채널과 동일 효과). firework.mp3(~1.4s) × 최대 7중첩 < 8보이스라 안전.
  final List<AudioPlayer> _fireworkPool = [
    AudioPlayer(playerId: 'firework_0'),
    AudioPlayer(playerId: 'firework_1'),
    AudioPlayer(playerId: 'firework_2'),
    AudioPlayer(playerId: 'firework_3'),
    AudioPlayer(playerId: 'firework_4'),
    AudioPlayer(playerId: 'firework_5'),
    AudioPlayer(playerId: 'firework_6'),
    AudioPlayer(playerId: 'firework_7'),
  ];
  int _fwIdx = 0;
  // 오브제(공) 스퀴시·릴리스 round-robin 풀(빠른 연속 터치가 서로 안 끊기게).
  final List<AudioPlayer> _objetPool = [
    AudioPlayer(playerId: 'objet_0'),
    AudioPlayer(playerId: 'objet_1'),
    AudioPlayer(playerId: 'objet_2'),
  ];
  int _objetIdx = 0;
  DateTime _objetLast = DateTime.fromMillisecondsSinceEpoch(0);
  // 쫀득·몰캉 스트레치(떡 늘어나는) 레이어 풀 — slime과 동시에 깔리도록 별도 채널.
  final List<AudioPlayer> _chewyPool = [
    AudioPlayer(playerId: 'chewy_0'),
    AudioPlayer(playerId: 'chewy_1'),
  ];
  int _chewyIdx = 0;
  DateTime _chewyLast = DateTime.fromMillisecondsSinceEpoch(0);
  // 문지르기 연속 루프(끊김 없는 부드러운 rub) — 별도 채널 + 페이드 인/아웃.
  final AudioPlayer _rub = AudioPlayer(playerId: 'objet_rub');
  bool _rubOn = false;
  Timer? _rubFade;
  // 웹 루프 안전망: 일부 브라우저에서 ReleaseMode.loop가 자동 반복되지 않아 클립이
  // 한 번 재생되고 멈추는 문제 → 클립 완료를 구독해 손 뗄 때까지 수동으로 다시 잇는다.
  StreamSubscription<void>? _rubLoopSub;
  // 문지르기 rub 루프 볼륨. 0.34는 폰에서 거의 안 들린다는 피드백(2026-06-08)으로
  // 0.62로 상향 — 다른 효과음(slime 0.5~0.9)에 묻히지 않고 또렷이 들리게.
  static const double _kRubVolume = 0.62;
  // 글쓰기 타이핑 round-robin 풀.
  final List<AudioPlayer> _typePool = [
    AudioPlayer(playerId: 'type_0'),
    AudioPlayer(playerId: 'type_1'),
  ];
  int _typeIdx = 0;
  DateTime _typeLast = DateTime.fromMillisecondsSinceEpoch(0);
  final Random _rng = Random();

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

  // _loop을 release 모드로 재생하고 클립이 끝나면 손수 다시 이어 "수동 루프"를 만든다.
  // ReleaseMode.loop가 일부 기기에서 mp3를 무음 처리하는 문제 회피(fire/shred 무음 수정).
  Future<void> _startLoopManual(String asset, double volume) => _safe(() async {
        _loopAsset = asset;
        _loopVol = volume;
        await _loop.stop();
        await _loop.setReleaseMode(ReleaseMode.release); // loop 모드 미사용(무음 버그 회피)
        await _loop.setVolume(volume);
        await _loop.play(AssetSource(asset), volume: volume);
        _loopCompleteSub?.cancel();
        _loopCompleteSub = _loop.onPlayerComplete.listen((_) {
          final a = _loopAsset;
          if (a != null) _loop.play(AssetSource(a), volume: _loopVol);
        });
      });

  Future<void> _stopLoopManual() => _safe(() async {
        _loopAsset = null;
        _loopCompleteSub?.cancel();
        _loopCompleteSub = null;
        await _loop.stop();
      });

  // ── 태우기 ───────────────────────────────────────────────────────────────
  /// 연소 시작 — fire.mp3 루프(volume 1.0). release+수동 반복(loop 모드 무음 버그 회피).
  Future<void> startFire() => _startLoopManual('audio/fire.mp3', 1.0);

  /// 연소 종료(전소) — fire 루프 정지.
  Future<void> stopFire() => _stopLoopManual();

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
  /// 분쇄 시작 — shred.mp3 루프(volume 1.0). release+수동 반복(loop 모드 무음 버그 회피).
  Future<void> startShred() => _startLoopManual('audio/shred.mp3', 1.0);

  /// 분쇄 종료 — shred 루프 정지.
  Future<void> stopShred() => _stopLoopManual();

  /// 폭죽 — firework.mp3 원샷(volume 0.85). 폭죽이 터지는 매 타이밍마다 호출.
  /// 6보이스 풀 라운드로빈으로 빠른 연속('팡팡')이 서로 끊기지 않게 한다(채널 스틸링 방지).
  /// 다음 보이스를 stop() 없이 그대로 재생해(직전 보이스의 잔향을 끊지 않음) 겹쳐 울린다.
  Future<void> firework() => _safe(() async {
        final p = _fireworkPool[_fwIdx];
        _fwIdx = (_fwIdx + 1) % _fireworkPool.length;
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
    const stepMs = 80; // 드물게(클립당 1회) + 낮은 호출빈도 → 잰크 위험 최소.
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
    const stepMs = 80; // 페이드 볼륨 램프는 낮은 빈도로도 매끄럽다(잰크 최소).
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

  // ── 오브제(공) ─────────────────────────────────────────────────────────────
  /// 공 만지기 — slime 스퀴시 슬라이스 random 재생(round-robin). throttle=true면
  /// 연속 제스처(쓰다듬기·굴리기) 스팸을 막기 위해 ~70ms 간격 제한.
  Future<void> objetSquish({double gain = 0.9, bool throttle = false}) {
    if (throttle) {
      final now = DateTime.now();
      if (now.difference(_objetLast).inMilliseconds < 70) return Future.value();
      _objetLast = now;
    }
    return _safe(() async {
      final p = _objetPool[_objetIdx];
      _objetIdx = (_objetIdx + 1) % _objetPool.length;
      await p.stop();
      await p.setReleaseMode(ReleaseMode.release);
      await p.play(AssetSource('audio/slime_${_rng.nextInt(6)}.wav'),
          volume: gain);
    });
  }

  /// 떡 늘어나는 쫀득·몰캉 스트레치 레이어 — mochi 슬라이스 random 재생(별도 채널).
  /// slime과 동시에 깔려 말랑이 만지는 질감을 더한다. ~90ms throttle.
  Future<void> objetStretch({double gain = 0.5}) {
    final now = DateTime.now();
    if (now.difference(_chewyLast).inMilliseconds < 90) return Future.value();
    _chewyLast = now;
    return _safe(() async {
      final p = _chewyPool[_chewyIdx];
      _chewyIdx = (_chewyIdx + 1) % _chewyPool.length;
      await p.stop();
      await p.setReleaseMode(ReleaseMode.release);
      await p.play(AssetSource('audio/mochi_${_rng.nextInt(4)}.wav'),
          volume: gain);
    });
  }

  /// 공에서 손 뗄 때 — squelch 슬라이스 random 재생(round-robin).
  Future<void> objetSquelch({double gain = 1.0}) => _safe(() async {
        final p = _objetPool[_objetIdx];
        _objetIdx = (_objetIdx + 1) % _objetPool.length;
        await p.stop();
        await p.setReleaseMode(ReleaseMode.release);
        await p.play(AssetSource('audio/squelch_${_rng.nextInt(3)}.wav'),
            volume: gain);
      });

  /// 문지르기 시작 — 부드러운 rub 루프를 페이드인으로 켠다(이미 켜져 있으면 무시).
  /// 손을 뗄 때까지 끊김 없이 이어진다(슬라이스 retrigger 대신 연속 루프).
  Future<void> startRub() => _safe(() async {
        if (_rubOn) return;
        _rubOn = true;
        _rubFade?.cancel();
        await _rub.setReleaseMode(ReleaseMode.loop);
        // 웹은 volume:0 시작이 재생 자체를 막는 경우가 있어 들리는 볼륨으로 바로 재생한 뒤
        // setVolume으로 부드럽게 차오르게 한다(무음 0 시작 회피).
        await _rub.play(AssetSource('audio/rub.wav'), volume: _kRubVolume);
        await _rub.setVolume(_kRubVolume * 0.25);
        // 웹 루프 안전망: loop가 자동 반복 안 되는 브라우저에서 클립이 끝나면 손 뗄
        // 때까지 다시 잇는다(네이티브는 loop가 자동이라 onPlayerComplete가 안 울려 무해).
        _rubLoopSub?.cancel();
        _rubLoopSub = _rub.onPlayerComplete.listen((_) {
          if (_rubOn) {
            _rub.play(AssetSource('audio/rub.wav'), volume: _kRubVolume);
          }
        });
        // 부드러운 페이드인(30ms×9≈270ms) — 문지르기 시작이 톡 튀지 않고 스르륵 차오른다.
        const stepMs = 30;
        const steps = 9;
        var i = 0;
        _rubFade = Timer.periodic(const Duration(milliseconds: stepMs), (t) {
          i++;
          _rub.setVolume(_kRubVolume * (0.25 + 0.75 * (i / steps)));
          if (i >= steps) t.cancel();
        });
      });

  /// 문지르기 종료 — rub 루프를 짧게 페이드아웃 후 정지(클릭 방지).
  Future<void> stopRub() => _safe(() async {
        if (!_rubOn) return;
        _rubOn = false;
        _rubFade?.cancel();
        _rubLoopSub?.cancel(); // 수동 재반복 안전망 해제(더 안 잇게)
        _rubLoopSub = null;
        // 부드러운 페이드아웃(30ms×9≈270ms) — 손 뗄 때 뚝 끊기지 않고 스르륵 잦아든다.
        const stepMs = 30;
        const steps = 9;
        var i = 0;
        const start = _kRubVolume;
        _rubFade = Timer.periodic(const Duration(milliseconds: stepMs), (t) {
          i++;
          final v = start * (1 - i / steps);
          _rub.setVolume(v < 0 ? 0 : v);
          if (i >= steps) {
            t.cancel();
            _rub.stop();
          }
        });
      });

  // ── 글쓰기 ─────────────────────────────────────────────────────────────────
  /// 키 입력 — type 슬라이스 random 재생(round-robin, ~40ms throttle).
  Future<void> typeKey({double gain = 0.9}) {
    final now = DateTime.now();
    if (now.difference(_typeLast).inMilliseconds < 40) return Future.value();
    _typeLast = now;
    return _safe(() async {
      final p = _typePool[_typeIdx];
      _typeIdx = (_typeIdx + 1) % _typePool.length;
      await p.stop();
      await p.setReleaseMode(ReleaseMode.release);
      await p.play(AssetSource('audio/type_${_rng.nextInt(5)}.wav'),
          volume: gain);
    });
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
        _loopAsset = null; // 수동 루프 정지(재이음 방지)
        _loopCompleteSub?.cancel();
        _loopCompleteSub = null;
        await _loop.stop();
        await _shotA.stop();
        await _shotB.stop();
        await _emberLoop.stop();
        await _skyA.stop();
        await _skyB.stop();
        for (final p in _objetPool) {
          await p.stop();
        }
        for (final p in _chewyPool) {
          await p.stop();
        }
        for (final p in _typePool) {
          await p.stop();
        }
        for (final p in _fireworkPool) {
          await p.stop();
        }
        _rubOn = false;
        _rubFade?.cancel();
        _rubLoopSub?.cancel();
        _rubLoopSub = null;
        await _rub.stop();
      });
}
