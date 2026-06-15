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

  // 의식 루프(fire/shred) 전용 보이스 풀.
  // 기존 단일 `_loop` 인스턴스(playerId 'ritual_loop')가 실기기에서 무음이었다
  // (2026-06-12: release 모드로 바꿔도 `_loop`만 무음, 폭죽/ember는 정상 → 인스턴스
  // 문제). → 폭죽이 정상 재생되는 것과 동일하게, 새 전용 보이스에 release 원샷으로
  // 재생한다. fire.mp3(~2.5분)·shred.mp3(~4초)는 의식 길이를 한 번 재생으로 덮으며,
  // 혹시 짧으면 onPlayerComplete에서 다른 보이스로 이어 끊김 없이 지속한다.
  final List<AudioPlayer> _ritualLoopPool = [
    AudioPlayer(playerId: 'ritual_loop_a'),
    AudioPlayer(playerId: 'ritual_loop_b'),
  ];
  int _rlIdx = 0;
  String? _loopAsset; // 현재 재생 중인 에셋 경로(null이면 정지)
  double _loopVol = 1.0;
  StreamSubscription<void>? _loopCompleteSub;
  final AudioPlayer _shotA = AudioPlayer(playerId: 'ritual_shot_a');
  final AudioPlayer _shotB = AudioPlayer(playerId: 'ritual_shot_b');
  // 종이비행기 당김 '도도도' 긴장 틱 — 당김 거리마다 짧은 톤. 세게 당길수록 음↑·소리↑.
  // 빠른 연속 틱이 서로 안 끊기게 2보이스 라운드로빈 + playbackRate로 음정 변조.
  final List<AudioPlayer> _pullPool = [
    AudioPlayer(playerId: 'plane_pull_0'),
    AudioPlayer(playerId: 'plane_pull_1'),
  ];
  int _pullIdx = 0;
  // 잔불 타닥타닥(단순 루프 — crackle은 경계가 조용해 갭이 안 들림).
  final AudioPlayer _emberLoop = AudioPlayer(playerId: 'ritual_ember');
  // 하늘 앰비언트 더블버퍼(끊김 없는 루프 — 두 플레이어를 크로스페이드).
  final AudioPlayer _skyA = AudioPlayer(playerId: 'ritual_sky_a');
  final AudioPlayer _skyB = AudioPlayer(playerId: 'ritual_sky_b');
  // 폭죽 원샷 보이스 풀(채널 스틸링 방지) — 파쇄기 피날레는 3초 동안 폭죽음을 11발
  // 호출한다(0ms + 예약 10발). firework.mp3는 잔향 포함 길이가 길어(~2.5s+) 8보이스로는
  // 후반 폭죽(2550·2700·2880ms)이 초반(0·550·720ms)에 쓴 보이스를 아직 재생 중인데
  // 재사용 → 앞 소리가 끊겼다(#6 사용자 피드백). → 16보이스로 늘려 한 피날레의 11발이
  // 라운드로빈에서 절대 서로 겹치지 않게(각자 채널) 해, 모두 자연스럽게 겹쳐 울린다.
  final List<AudioPlayer> _fireworkPool = [
    AudioPlayer(playerId: 'firework_0'),
    AudioPlayer(playerId: 'firework_1'),
    AudioPlayer(playerId: 'firework_2'),
    AudioPlayer(playerId: 'firework_3'),
    AudioPlayer(playerId: 'firework_4'),
    AudioPlayer(playerId: 'firework_5'),
    AudioPlayer(playerId: 'firework_6'),
    AudioPlayer(playerId: 'firework_7'),
    AudioPlayer(playerId: 'firework_8'),
    AudioPlayer(playerId: 'firework_9'),
    AudioPlayer(playerId: 'firework_10'),
    AudioPlayer(playerId: 'firework_11'),
    AudioPlayer(playerId: 'firework_12'),
    AudioPlayer(playerId: 'firework_13'),
    AudioPlayer(playerId: 'firework_14'),
    AudioPlayer(playerId: 'firework_15'),
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
  // 말랑이 누르기(press) 시작 전용 효과음(사용자 제공 영상 추출, press.wav).
  // 지연 최소화 위해 프리로드(ReleaseMode.stop + setSource) 후 seek(0)+resume로 재생.
  final AudioPlayer _press = AudioPlayer(playerId: 'objet_press');
  bool _pressWarmed = false;
  // 말랑이 떼기(release) 전용 효과음(사용자 제공 영상 추출, release.wav). 동일 프리로드 패턴.
  final AudioPlayer _release = AudioPlayer(playerId: 'objet_release');
  bool _releaseWarmed = false;
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
  // 글쓰기 타이핑 — 슬라이스별 전용 플레이어(5개)를 미리 로드해 지연 최소화(#3).
  // 기존엔 2보이스에 매번 release+play(AssetSource)라 키마다 네이티브 재준비→지연.
  // ReleaseMode.stop + setSource 프리로드 후 키 입력마다 seek(0)+resume만(재준비 없음).
  // 라운드로빈으로 키마다 다른 슬라이스를 써서 변주 + 같은 보이스 재시작 충돌 회피.
  final List<AudioPlayer> _typeVoices = [
    for (var i = 0; i < 5; i++) AudioPlayer(playerId: 'type_$i'),
  ];
  bool _typeWarmed = false;
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

  // 앱이 백그라운드면 true — 새 재생을 막는다(앱 종료 후 소리 잔존 방지 — #1).
  bool _suspended = false;

  // 현재 돌고 있는 '지속 루프'를 다시 시작하는 함수(백그라운드 복귀 시 복원용 — #1 후속).
  // 잔불 타닥(ember)·하늘 두둥실(sky)·연소(fire)·분쇄(shred)가 시작될 때 세팅되고,
  // 각 정지/stopAll에서 비워진다. 복귀하면 이 함수를 다시 호출해 끊긴 소리를 되살린다.
  Future<void> Function()? _activeLoopStarter;
  Future<void> Function()? _pendingResume; // 백그라운드 진입 시점에 기억한 복원 함수

  /// 백그라운드 진입: 지속 루프를 기억해 두고 모든 소리를 멈춘 뒤 새 재생을 막는다(#1).
  Future<void> suspendForBackground() async {
    _pendingResume = _activeLoopStarter; // 복귀 시 되살릴 지속 루프 기억
    await stopAll(); // 실제 정지(아직 _suspended=false라 정상 동작)
    _suspended = true; // 이후 새 재생 차단
  }

  /// 포그라운드 복귀: 재생을 다시 허용하고, 백그라운드 직전 돌던 지속 루프를 복원한다(#1).
  Future<void> resumeFromBackground() async {
    _suspended = false;
    final resume = _pendingResume;
    _pendingResume = null;
    if (resume != null) await resume();
  }

  /// iOS 무음 스위치와 무관하게 효과음이 들리도록 playback 컨텍스트로 1회 설정.
  Future<void> _boot() async {
    if (_booted) return;
    _booted = true;
    try {
      // #6: 폭죽처럼 빠르게 겹치는 SFX가 서로 끊기지 않게 '미디어' 컨텍스트로.
      // 기존 sonification+gainTransientMayDuck(기본값 gain)은 새 재생이 오디오 포커스를
      // 독점해 앞 소리를 덕킹/중단시켰다. media+music+focus 없음으로 바꿔 여러 스트림이
      // 게임 SFX처럼 자유롭게 동시에 섞이게 한다.
      final ctx = AudioContext(
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: const {AVAudioSessionOptions.mixWithOthers},
        ),
        android: const AudioContextAndroid(
          isSpeakerphoneOn: false,
          contentType: AndroidContentType.music,
          usageType: AndroidUsageType.media,
          audioFocus: AndroidAudioFocus.none,
        ),
      );
      await AudioPlayer.global.setAudioContext(ctx);
      // ★ #6 진짜 원인: 전역 setAudioContext는 '이미 생성된' 플레이어에는 적용되지
      //   않는다(audioplayers_android가 생성 시점 컨텍스트를 복사·보관). 우리 플레이어는
      //   전부 필드 초기화로 부팅 전에 만들어져 기본값(audioFocus: gain = 독점 포커스)을
      //   그대로 갖고 있어, 새 재생마다 포커스를 가로채 앞 소리를 끊었다(폭죽 끊김).
      //   → 각 플레이어에 컨텍스트를 직접 적용해야 비로소 동시 재생이 된다.
      for (final p in _allPlayers) {
        try {
          await p.setAudioContext(ctx);
        } catch (_) {}
      }
      await _warmPress(); // 누르기음 프리로드(첫 누르기부터 지연 없이)
      await _warmRelease(); // 떼기음 프리로드
    } catch (e) {
      debugPrint('RitualAudio boot 실패(무시): $e');
    }
  }

  /// 컨텍스트(audioFocus 등)를 일괄 적용하기 위한 전체 플레이어 목록.
  List<AudioPlayer> get _allPlayers => [
        ..._ritualLoopPool,
        _shotA,
        _shotB,
        ..._pullPool,
        _emberLoop,
        _skyA,
        _skyB,
        ..._fireworkPool,
        ..._objetPool,
        ..._chewyPool,
        _rub,
        _press,
        _release,
        ..._typeVoices,
      ];

  Future<void> _safe(Future<void> Function() body) async {
    if (_suspended) return; // 백그라운드면 새 재생 무시(#1).
    try {
      await _boot();
      await body();
    } catch (e) {
      debugPrint('RitualAudio 재생 실패(무시): $e');
    }
  }

  // _loop을 release 모드로 재생하고 클립이 끝나면 손수 다시 이어 "수동 루프"를 만든다.
  // 폭죽이 정상 재생되는 것과 동일한 경로(새 전용 보이스 + release 원샷)로 fire/shred를
  // 재생한다. 같은 보이스를 재생하면 무음이 될 수 있어, 클립이 끝나면(짧은 음원) 다음
  // 보이스로 번갈아 이어 의식 동안 끊김 없이 지속한다.
  Future<void> _startLoopManual(String asset, double volume) => _safe(() async {
        _loopAsset = asset;
        _loopVol = volume;
        await _playRitualLoopVoice();
      });

  Future<void> _playRitualLoopVoice() async {
    final a = _loopAsset;
    if (a == null) return;
    final p = _ritualLoopPool[_rlIdx];
    _rlIdx = (_rlIdx + 1) % _ritualLoopPool.length;
    await p.setReleaseMode(ReleaseMode.release);
    await p.play(AssetSource(a), volume: _loopVol);
    _loopCompleteSub?.cancel();
    _loopCompleteSub = p.onPlayerComplete.listen((_) {
      if (_loopAsset != null) _playRitualLoopVoice(); // 다음 보이스로 이어붙임
    });
  }

  Future<void> _stopLoopManual() => _safe(() async {
        _activeLoopStarter = null; // 지속 루프 종료 — 복원 대상 해제(#1 후속)
        _loopAsset = null;
        _loopCompleteSub?.cancel();
        _loopCompleteSub = null;
        for (final p in _ritualLoopPool) {
          await p.stop();
        }
      });

  /// 의식 루프(fire/shred) 점화 지연 제거(#3): 화면 진입 시 두 보이스에 미리 로드한다.
  /// setSource로 디코드까지 끝내 두면, 점화 시 _playRitualLoopVoice의 play()가 같은
  /// 소스라 재준비 없이(short-circuit) 즉시 시작된다(첫 prepare 지연 제거).
  Future<void> _preloadRitualLoop(String asset) => _safe(() async {
        for (final p in _ritualLoopPool) {
          try {
            await p.setReleaseMode(ReleaseMode.stop);
            await p.setSource(AssetSource(asset));
          } catch (_) {}
        }
      });

  // ── 태우기 ───────────────────────────────────────────────────────────────
  /// 연소 시작 — fire.mp3 루프(volume 1.0). release+수동 반복(loop 모드 무음 버그 회피).
  Future<void> startFire() {
    _activeLoopStarter = startFire; // 백그라운드 복귀 복원용(#1 후속)
    return _startLoopManual('audio/fire.mp3', 1.0);
  }

  /// 태우기 화면 진입 시 호출 — fire.mp3를 미리 로드해 점화 지연 제거(#3).
  Future<void> preloadFire() => _preloadRitualLoop('audio/fire.mp3');

  /// 연소 종료(전소) — fire 루프 정지.
  Future<void> stopFire() => _stopLoopManual();

  /// 전소 후 잔불 타닥타닥 여운 — crackle.wav 루프(volume 0.7).
  Future<void> startEmberCrackle() {
    _activeLoopStarter = startEmberCrackle; // 백그라운드 복귀 복원용(#1 후속)
    return _safe(() async {
      await _emberLoop.stop();
      await _emberLoop.setReleaseMode(ReleaseMode.loop);
      await _emberLoop.setVolume(0.7);
      await _emberLoop.play(AssetSource('audio/crackle.wav'), volume: 0.7);
    });
  }

  /// 잔불 여운 정지.
  Future<void> stopEmberCrackle() {
    _activeLoopStarter = null; // 지속 루프 종료 — 복원 대상 해제(#1 후속)
    return _safe(() => _emberLoop.stop());
  }

  // ── 파쇄기 ───────────────────────────────────────────────────────────────
  /// 분쇄 시작 — shred.mp3 루프(volume 1.0). release+수동 반복(loop 모드 무음 버그 회피).
  Future<void> startShred() {
    _activeLoopStarter = startShred; // 백그라운드 복귀 복원용(#1 후속)
    return _startLoopManual('audio/shred.mp3', 1.0);
  }

  /// 파쇄기 화면 진입 시 호출 — shred.mp3를 미리 로드해 점화 지연 제거(#3).
  Future<void> preloadShred() => _preloadRitualLoop('audio/shred.mp3');

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

  /// 당김 '도도도' 긴장 틱 — 비행기를 당기는 동안 일정 거리마다 호출(슬링샷 장전 긴장감).
  /// 당김 세기 p(0~1)가 클수록 음정(playbackRate)·음량을 올려 "도→도↗→도↗" 빌드업.
  Future<void> planePullTension(double p) => _safe(() async {
        final v = p.clamp(0.0, 1.0);
        final player = _pullPool[_pullIdx];
        _pullIdx = (_pullIdx + 1) % _pullPool.length;
        await player.setReleaseMode(ReleaseMode.release);
        // 더 크게(0.8~1.0) + 음정 변화 폭을 넓혀(0.78~1.95) 게이지 따라 또렷이 상승.
        await player.play(AssetSource('audio/pull_tension.wav'),
            volume: 0.8 + v * 0.2);
        await player.setPlaybackRate(0.78 + v * 1.17); // 세게 당길수록 음↑(체감 ↑)
      });

  /// '하늘 두둥실' 포근한 앰비언트 — 두 플레이어 크로스페이드 더블버퍼로 끊김 없이
  /// 무한 루프. 비행음(whoosh)이 끝나는 즈음 호출하면 볼륨 0→0.5 페이드인(그라데이션)
  /// 으로 자연스럽게 이어진다. 이미 돌고 있으면(중복 호출) 무시한다.
  Future<void> startSky() {
    _activeLoopStarter = startSky; // 백그라운드 복귀 복원용(#1 후속)
    return _safe(() async {
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
  }

  /// 하늘 앰비언트 정지('처음으로' 탭 등) — 타이머·두 플레이어 모두 정리.
  Future<void> stopSky() => _safe(_stopSkyInternal);

  Future<void> _stopSkyInternal() async {
    if (identical(_activeLoopStarter, startSky)) {
      _activeLoopStarter = null; // 하늘 루프 종료 — 복원 대상 해제(#1 후속)
    }
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
  /// 말랑이 누르기(press) 시작음 — 사용자 제공 영상에서 추출한 press.wav 1종.
  /// 지연 최소화: 프리로드(setSource) 후 seek(0)+resume만(매번 재준비 없음, #3 패턴).
  Future<void> objetPress({double gain = 1.0}) => _safe(() async {
        await _warmPress();
        await _press.setVolume(gain.clamp(0.0, 1.0));
        await _press.seek(Duration.zero);
        await _press.resume();
      });

  /// press.wav를 전용 플레이어에 1회 프리로드(idempotent).
  Future<void> _warmPress() async {
    if (_pressWarmed) return;
    _pressWarmed = true;
    try {
      await _press.setReleaseMode(ReleaseMode.stop);
      await _press.setSource(AssetSource('audio/press.wav'));
    } catch (_) {}
  }

  /// 말랑이 떼기(release) 소리 — 사용자 제공 영상에서 추출한 release.wav 1종(프리로드+재생).
  Future<void> objetRelease({double gain = 1.0}) => _safe(() async {
        await _warmRelease();
        await _release.setVolume(gain.clamp(0.0, 1.0));
        await _release.seek(Duration.zero);
        await _release.resume();
      });

  /// release.wav를 전용 플레이어에 1회 프리로드(idempotent).
  Future<void> _warmRelease() async {
    if (_releaseWarmed) return;
    _releaseWarmed = true;
    try {
      await _release.setReleaseMode(ReleaseMode.stop);
      await _release.setSource(AssetSource('audio/release.wav'));
    } catch (_) {}
  }

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
  /// 글쓰기 화면 진입 시 호출 — 타이핑 슬라이스를 미리 로드해 첫 키부터 지연 없이(#3).
  Future<void> preloadTyping() => _safe(_warmTypeVoices);

  /// 타이핑 슬라이스(type_0~4)를 각 전용 플레이어에 1회 프리로드(idempotent).
  /// ReleaseMode.stop + setSource로 디코드까지 끝내 둬, 재생은 seek(0)+resume만 한다.
  Future<void> _warmTypeVoices() async {
    if (_typeWarmed) return;
    _typeWarmed = true;
    for (var i = 0; i < _typeVoices.length; i++) {
      try {
        await _typeVoices[i].setReleaseMode(ReleaseMode.stop);
        await _typeVoices[i].setSource(AssetSource('audio/type_$i.wav'));
      } catch (_) {}
    }
  }

  /// 키 입력 — 미리 로드된 슬라이스 보이스를 round-robin으로 seek(0)+resume(저지연, #3).
  /// (release+play(AssetSource)의 매회 네이티브 재준비 지연 제거.) ~40ms throttle.
  Future<void> typeKey({double gain = 0.9}) {
    final now = DateTime.now();
    if (now.difference(_typeLast).inMilliseconds < 40) return Future.value();
    _typeLast = now;
    return _safe(() async {
      await _warmTypeVoices(); // 프리로드 누락 대비(이미 됐으면 즉시 반환)
      final p = _typeVoices[_typeIdx];
      _typeIdx = (_typeIdx + 1) % _typeVoices.length;
      await p.setVolume(gain);
      await p.seek(Duration.zero);
      await p.resume();
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
        _activeLoopStarter = null; // 모든 지속 루프 종료 — 복원 대상 해제(#1 후속)
        _skyRunning = false;
        _skySwap?.cancel();
        _skyXfade?.cancel();
        _skyFadeIn?.cancel();
        _loopAsset = null; // 의식 루프 정지(재이음 방지)
        _loopCompleteSub?.cancel();
        _loopCompleteSub = null;
        for (final p in _ritualLoopPool) {
          await p.stop();
        }
        await _shotA.stop();
        await _shotB.stop();
        for (final p in _pullPool) {
          await p.stop();
        }
        await _emberLoop.stop();
        await _skyA.stop();
        await _skyB.stop();
        for (final p in _objetPool) {
          await p.stop();
        }
        await _press.stop();
        await _release.stop();
        for (final p in _chewyPool) {
          await p.stop();
        }
        for (final p in _typeVoices) {
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
