import 'dart:async';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// 홈(감정 공·말랑이) 제스처 효과음 재생기 (싱글턴).
///
/// 프로토타입(todaktodakhaejo/Prototype, sfx.ts)의 '공 사운드' 설계를 그대로 옮긴다.
/// 진동(햅틱)에 1:1로 짝지어, 누르기·떼기·쓰다듬기·벽충돌 순간에 잔잔한 질감음을 얹는다.
///
/// 설계 요지(전부 같은 `slime.mp3` 한 파일을 rate/volume/길이만 다르게 짧게 재생):
/// - [press]  : rate 0.9, vol 1.0,  ~0.42s — 쑥 들어가는 묵직한 '말랑'.
/// - [release]: rate 1.1, vol 0.95, ~0.40s — 톡 차오르는 '뽕'.
/// - [rub]    : rate 1.35, vol 0.5, ~0.16s — 자주 울리므로 여리게 + throttle(~100ms).
/// - [wall]   : rate 0.8,  vol 0.7+strength*0.4, ~0.28s — 충돌 세기로 볼륨 차등.
/// 각 재생은 랜덤 위치에서 시작(같은 소리가 반복돼도 단조롭지 않게)하고, 해당 길이만큼만
/// 재생한 뒤 정지한다. 클립이 길어(원본 slime.mp3가 김) 짧게 잘라 쓰며, 정지 직전 살짝
/// 볼륨 페이드로 '딱' 끊기는 클릭을 줄인다.
///
/// **오디오는 audioplayers 단일 플러그인만 사용**(P3 [RitualAudio]와 동일 정책).
/// RitualAudio(의식 사운드)와는 **완전히 분리**된 플레이어 풀을 쓴다 — 서로 채널을
/// 침범하지 않는다.
///
/// 햅틱과 마찬가지로 "켜고 끄는" 얇은 파사드. 사운드를 못 넣는 환경(시뮬레이터·웹·
/// 미지원·무음 스위치)에서도 제스처/햅틱이 정상 동작하도록 **모든 호출을 best-effort
/// (예외 무시)** 로 감싸고, 실패하면 조용히 noop 한다.
class HomeSfx {
  HomeSfx._();
  static final HomeSfx instance = HomeSfx._();

  final Random _rng = Random();

  // ── 보이스 풀 ───────────────────────────────────────────────────────────
  // 빠른 연속(특히 rub·연속 벽튕김)이 서로 끊기지 않도록 3개 플레이어를 라운드로빈.
  // 같은 종류라도 서로 다른 보이스로 가므로 직전 소리를 잘라먹지 않는다.
  static const int _kVoices = 3;
  late final List<AudioPlayer> _pool = List<AudioPlayer>.generate(
    _kVoices,
    (i) => AudioPlayer(playerId: 'home_sfx_$i'),
  );
  int _next = 0;

  // 각 보이스마다 '짧게 재생 후 정지' 타이머. 새 재생이 같은 보이스를 재사용하면
  // 직전 타이머를 취소해 조기 정지로 인한 끊김을 막는다.
  final List<Timer?> _stopTimers = List<Timer?>.filled(_kVoices, null);
  final List<Timer?> _fadeTimers = List<Timer?>.filled(_kVoices, null);

  // slime.mp3 한 파일만 사용(프로토타입과 동일). squelch.mp3는 롱프레스-완료 동작이
  // 우리 앱엔 없어 현재 미사용(에셋은 향후 확장 대비 등록만 유지).
  static final AssetSource _slime = AssetSource('audio/slime.mp3');

  // 원본 클립 길이 가정(랜덤 시작 위치 산정용). 정확치 않아도 무방 —
  // 시작 위치가 길이를 넘으면 audioplayers가 알아서 처리/무음이 되며, best-effort라
  // 흐름을 막지 않는다. 보수적으로 ~1.2s 안쪽에서만 시작점을 잡는다.
  static const Duration _kClipLen = Duration(milliseconds: 1200);

  // rub은 매우 자주 호출되므로 자체 throttle(프로토타입 90~120ms 권장 → 100ms).
  static const Duration _kRubGap = Duration(milliseconds: 100);
  DateTime _rubLast = DateTime.fromMillisecondsSinceEpoch(0);

  bool _booted = false;

  /// iOS 무음 스위치/미디어 볼륨으로 들리도록 playback 컨텍스트를 1회 설정.
  /// (도움말에 '벨소리·볼륨 ON' 안내가 있으므로 무음 스위치 시 무음은 허용.)
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
      debugPrint('HomeSfx boot 실패(무시): $e');
    }
  }

  /// 앱 시작/첫 제스처에 1회 호출 권장 — 오디오 컨텍스트 설정(unlock) 선반영.
  /// 미호출이어도 각 재생 시 [_boot]이 게으르게 실행되므로 필수는 아니다.
  Future<void> warmUp() => _boot();

  /// 짧은 효과음 1회 재생. [rate] 재생속도, [volume] 0~1, [dur] 재생 길이.
  /// 보이스 풀에서 다음 플레이어를 골라 랜덤 시작 위치에서 [dur]만큼 재생하고
  /// 정지한다(정지 직전 짧은 페이드로 클릭 방지). 전부 best-effort.
  Future<void> _shot({
    required double rate,
    required double volume,
    required Duration dur,
  }) async {
    try {
      await _boot();
      final i = _next;
      _next = (_next + 1) % _kVoices;
      final p = _pool[i];

      // 직전 이 보이스의 정지/페이드 타이머 취소(재사용 시 조기 정지 방지).
      _stopTimers[i]?.cancel();
      _fadeTimers[i]?.cancel();

      // 랜덤 시작 위치(0 ~ clip-dur). 같은 소리가 반복돼도 단조롭지 않게.
      final maxStartMs =
          (_kClipLen.inMilliseconds - dur.inMilliseconds).clamp(0, 1 << 30);
      final startMs = maxStartMs == 0 ? 0 : _rng.nextInt(maxStartMs);

      await p.stop(); // 같은 보이스의 직전 소리는 끊고 새로(solo) 시작.
      await p.setReleaseMode(ReleaseMode.stop);
      await p.setPlaybackRate(rate);
      await p.setVolume(volume.clamp(0.0, 1.0));
      await p.play(_slime, volume: volume.clamp(0.0, 1.0));
      if (startMs > 0) {
        await p.seek(Duration(milliseconds: startMs));
      }

      // 끝에서 살짝 볼륨 페이드(클릭 방지) → dur 경과 시 정지.
      _scheduleFadeStop(i, p, volume.clamp(0.0, 1.0), dur);
    } catch (e) {
      debugPrint('HomeSfx 재생 실패(무시): $e');
    }
  }

  // 재생 길이 [dur]의 끝 ~70ms 구간에서 볼륨을 0으로 내리고(클릭 방지), dur 경과 시 정지.
  void _scheduleFadeStop(int i, AudioPlayer p, double vol, Duration dur) {
    const fadeMs = 70;
    final totalMs = dur.inMilliseconds;
    final fadeStartMs = (totalMs - fadeMs).clamp(0, totalMs);

    _fadeTimers[i] = Timer(Duration(milliseconds: fadeStartMs), () {
      // 짧은 선형 램프로 vol→0 (몇 스텝만 — 잰크 최소).
      const steps = 4;
      var s = 0;
      Timer.periodic(const Duration(milliseconds: fadeMs ~/ steps), (t) {
        s++;
        final v = (vol * (1 - s / steps)).clamp(0.0, 1.0);
        // 페이드 도중 새 재생이 이 보이스를 가져갔으면 더 건드리지 않는다.
        p.setVolume(v).catchError((_) {});
        if (s >= steps) t.cancel();
      });
    });

    _stopTimers[i] = Timer(dur, () {
      p.stop().catchError((_) {});
    });
  }

  // ── 제스처별 시그니처 사운드 (프로토타입 sfx.ts와 1:1) ──────────────────

  /// 누르는 순간(hapticPress 짝). slime rate 0.9, vol 1.0, ~0.42s — 묵직한 '말랑'.
  Future<void> press() => _shot(
        rate: 0.9,
        volume: 1.0,
        dur: const Duration(milliseconds: 420),
      );

  /// 떼는 순간(hapticRelease 짝). slime rate 1.1, vol 0.95, ~0.40s — 톡 차오름.
  Future<void> release() => _shot(
        rate: 1.1,
        volume: 0.95,
        dur: const Duration(milliseconds: 400),
      );

  /// 문지름=쓰다듬기(hapticRubTick=strokeSoft 짝). slime rate 1.35, vol 0.5, ~0.16s.
  /// 자주 울리므로 여리게 + 내장 throttle(~100ms)로 폭주를 막는다.
  Future<void> rub() async {
    final now = DateTime.now();
    if (now.difference(_rubLast) < _kRubGap) return;
    _rubLast = now;
    await _shot(
      rate: 1.35,
      volume: 0.5,
      dur: const Duration(milliseconds: 160),
    );
  }

  /// 벽 충돌(hapticWallHit 짝). slime rate 0.8, vol 0.7+strength*0.4, ~0.28s.
  /// [strength](0~1, 충돌 세기)로 볼륨을 차등 — 세게 부딪칠수록 크게.
  Future<void> wall(double strength) {
    final s = strength.clamp(0.0, 1.0);
    return _shot(
      rate: 0.8,
      volume: 0.7 + s * 0.4, // 0.7~1.1 → _shot에서 1.0으로 clamp.
      dur: const Duration(milliseconds: 280),
    );
  }

  /// 화면 dispose 시 호출 — 잔여 타이머/재생을 모두 정지(다음 화면으로 안 샘).
  /// best-effort. 호출 후에도 (싱글턴이므로) 다시 사용 가능하다.
  Future<void> stopAll() async {
    for (var i = 0; i < _kVoices; i++) {
      _stopTimers[i]?.cancel();
      _fadeTimers[i]?.cancel();
      _stopTimers[i] = null;
      _fadeTimers[i] = null;
      try {
        await _pool[i].stop();
      } catch (e) {
        debugPrint('HomeSfx stopAll 실패(무시): $e');
      }
    }
  }
}
