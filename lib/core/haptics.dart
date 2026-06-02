import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/animation.dart';
import 'package:flutter/services.dart';

/// 햅틱 세기 단계. Flutter 내장 HapticFeedback은 고정 단계만 제공하므로
/// 충격 세기(impact strength)를 이 단계로 매핑해서 사용한다.
enum HapticLevel { selection, light, medium, heavy, success }

/// 앱 전역 햅틱 엔진.
///
/// - 제스처 인터랙션에서는 [impactBySpeed]로 충돌 세기에 맞춰 진동.
/// - 의식(분출) 연출에서는 [playTimeline]으로 애니메이션 진행도(0~1)의
///   키프레임마다 햅틱 큐를 발사 → 모션과 진동이 한 축에서 움직인다.
class Haptics {
  Haptics._();
  static final Haptics instance = Haptics._();

  final Duration _minGap = const Duration(milliseconds: 28);
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  /// 너무 잦은 진동 방지용 throttle. 직전 발사 후 [_minGap] 이내면 무시.
  bool _allow() {
    final now = DateTime.now();
    if (now.difference(_last) < _minGap) return false;
    _last = now;
    return true;
  }

  void fire(HapticLevel level, {bool throttle = true}) {
    if (throttle && !_allow()) return;
    switch (level) {
      case HapticLevel.selection:
        HapticFeedback.selectionClick();
      case HapticLevel.light:
        HapticFeedback.lightImpact();
      case HapticLevel.medium:
        HapticFeedback.mediumImpact();
      case HapticLevel.heavy:
        HapticFeedback.heavyImpact();
      case HapticLevel.success:
        // 완료감: heavy 한 번. (iOS Core Haptics 연동 시 success 패턴으로 교체)
        HapticFeedback.heavyImpact();
    }
  }

  /// 0~1로 정규화된 강도를 단계로 매핑해 발사. (예: 벽 충돌 속도)
  void impactByStrength(double t, {bool throttle = true}) {
    final c = t.clamp(0.0, 1.0);
    if (c < 0.12) return; // 미세한 접촉은 무시
    final level = c < 0.35
        ? HapticLevel.light
        : c < 0.7
            ? HapticLevel.medium
            : HapticLevel.heavy;
    fire(level, throttle: throttle);
  }

  /// 속도(px/s 등 임의 단위)를 [maxSpeed] 기준으로 정규화해 발사.
  void impactBySpeed(double speed, {double maxSpeed = 2600}) {
    impactByStrength((speed / maxSpeed));
  }

  /// 잡고 문지르기(GST-04)용 지속적 약한 진동 틱.
  void rubTick() => fire(HapticLevel.light);

  // ── P3 신규: 부드러운 성공 / 연속 진동 근사 ──────────────────────
  // 의식 고도화(태우기 잔불 마무리·보석함 닫힘·파쇄기 투입)용.
  // 모두 graceful degradation: 미지원/웹에서 HapticFeedback은 무음 통과.

  /// 부드러운 성공 마무리. heavy 단발 대신 medium→(지연)→light 2펄스 디케이로
  /// '포근하게 잦아드는' 마무리감을 만든다. 보석함 뚜껑 닫힘·태우기 잔불용.
  ///
  /// 시퀀스이므로 [Future]로 await 가능(타이밍 동기화 필요 시).
  /// throttle을 우회해 두 펄스가 모두 발사되도록 한다.
  Future<void> softSuccess() async {
    // 첫 펄스: 살짝 묵직하게 안착감.
    fire(HapticLevel.medium, throttle: false);
    // 디케이 간격 후 약하게 한 번 더 — 여운처럼.
    await Future<void>.delayed(const Duration(milliseconds: 90));
    fire(HapticLevel.light, throttle: false);
  }

  /// 연속 진동 근사(파쇄기 '갈리는' 질감용).
  ///
  /// 내장 [HapticFeedback]엔 연속 진동이 없으므로 짧은 임팩트를 일정 간격으로
  /// 반복해 흉내낸다. [fire]의 28ms 글로벌 throttle을 우회하려고 자체 타이머로
  /// `throttle:false` 발사한다.
  ///
  /// [intensity](0~1)가 높을수록 더 강한 레벨·더 촘촘한 간격으로 울린다.
  /// [total]은 안전장치(자동 종료 시한)일 뿐 — **드래그 동안만 울리려면 반환된
  /// [RumbleHandle.stop]을 onDragEnd/dispose에서 반드시 호출**한다(무한진동·누수 방지).
  ///
  /// 사용 예:
  /// ```dart
  /// final rumble = Haptics.instance.rumble();      // onDragStart
  /// rumble.setIntensity(dragSpeedNormalized);       // onDragUpdate (선택)
  /// rumble.stop();                                  // onDragEnd / dispose
  /// ```
  RumbleHandle rumble({
    Duration total = const Duration(seconds: 8),
    double intensity = 0.5,
  }) {
    final handle = RumbleHandle._(this, intensity);
    handle._start(total);
    return handle;
  }

  /// [RumbleHandle]이 내부적으로 1펄스 발사할 때 사용(throttle 우회).
  void _rumblePulse(double intensity) {
    // 강도에 따라 레벨 양자화: 낮으면 light, 높으면 medium.
    final level = intensity >= 0.5 ? HapticLevel.medium : HapticLevel.light;
    fire(level, throttle: false);
  }

  // ── 파쇄기(shredder) 전용 햅틱 ──────────────────────────────────────
  // 명세 §5.3/§5.4. rumble과 형제이지만 grinding 고유의 '고조 곡선·말미
  // 촘촘함·모터 지터'를 내장한 별도 드라이버다(기존 rumble은 그대로 유지).
  //
  // ⚠️ 연속 진동은 OS 네이티브 미배선 → 짧은 임팩트를 타이머로 반복하는
  // **근사**가 전부다. 실제 '도는 모터' 질감 튜닝은 실기기에서만 검증 가능.
  // 미지원/웹에서는 [fire]가 HapticFeedback 무음 통과 → 예외 없이 무동작.

  /// 파쇄기 연속 그라인드(§5.3). 시작 즉시 모터 질감 연속 펄스가 돌기 시작한다.
  ///
  /// 3초 동안 staccato 펄스 묶음(3발 tight + 공백 반복, 말미 더 촘촘)으로 임팩트를
  /// 반복해 '잘게 끊기며 갈리는 모터'를 흉내낸다. 강도는 자체 경과시간 기반 기본
  /// 곡선(medium→heavy 고조)으로도 동작하며,
  /// [GrindHandle.setProgress]로 화면 진행도(0~1)를 주입하면 그 곡선을 따른다.
  ///
  /// 반환된 [GrindHandle.stop]을 **bursting 진입·dispose에서 반드시 호출**한다
  /// (무한 진동·타이머 누수 방지). 안전장치로 4초 후 자동 stop된다.
  GrindHandle startShredGrind() {
    final handle = GrindHandle._(this);
    handle._start();
    return handle;
  }

  /// [GrindHandle]이 1펄스 발사할 때 사용(throttle 우회).
  ///
  /// grind 강도(0~1)를 레벨로 양자화한다. 실기기 피드백(2026-06-01: 분쇄 진동이
  /// 너무 약함)으로 한 단계 끌어올렸다 — grinding엔 **light를 쓰지 않고** medium을
  /// 바닥, 중반 이후(≥0.62)와 최말미 고조 구간은 heavy를 상시 사용해 묵직하게 한다.
  /// (HapticFeedback의 천장은 heavyImpact. 더 센 '연속' 진동은 Core Haptics 필요.)
  void _grindPulse(double intensity, {bool spikeHeavy = false}) {
    final level = (intensity >= 0.62 || spikeHeavy)
        ? HapticLevel.heavy
        : HapticLevel.medium;
    fire(level, throttle: false);
  }

  // ── 태우기(burn) 전용 햅틱 ──────────────────────────────────────────
  // 명세 §4(햅틱). 파쇄기 [startShredGrind]의 **형제** 드라이버다 — 같은
  // '타이머로 짧은 임팩트를 반복하는 연속 진동 근사' 구조에, 태우기 고유의
  // '아래→위 화력 고조 곡선(0.55→1.0)·말미 촘촘함(35ms)·불 일렁임 지터'를
  // 내장한다(기존 [rumble]/[startShredGrind]는 그대로 유지).
  //
  // ⚠️ 연속 진동은 OS 네이티브 미배선 → 짧은 임팩트를 타이머로 반복하는
  // **근사**가 전부다. 실제 '타오르는 불' 질감(점점 강해지는 연속 진동)
  // 튜닝은 실기기에서만 검증 가능. 미지원/웹에서는 [fire]가 HapticFeedback
  // 무음 통과 → 예외 없이 무동작(§9 폴백).

  /// 태우기 연속 연소(§4 햅틱). 점화 시 시작, 불이 커질수록 강해지는 연속 진동.
  ///
  /// 3초 동안 ~45ms 간격(말미 35ms)으로 임팩트를 반복해 '아래→위로 활활 번지는
  /// 불길'을 흉내낸다. 강도는 자체 경과시간 기반 기본 곡선(medium→heavy 고조)으로도
  /// 동작하며, [BlazeHandle.setProgress]로 화면 `_burnCtrl.value`(0~1)를 매 프레임
  /// 주입하면 그 화력 곡선을 따른다.
  ///
  /// 반환된 [BlazeHandle.stop]을 **전소(softSuccess 직전)·dispose에서 반드시 호출**
  /// 한다(무한 진동·타이머 누수 방지). 안전장치로 4초 후 자동 stop된다.
  /// ⚠️ 마무리는 호출측이 [BlazeHandle.stop]을 [softSuccess]보다 **먼저** 부른다
  /// (겹침 방지) — 이 드라이버는 [softSuccess]를 직접 호출하지 않는다.
  BlazeHandle startBurnBlaze() {
    final handle = BlazeHandle._(this);
    handle._start();
    return handle;
  }

  /// [BlazeHandle]이 1펄스 발사할 때 사용(throttle 우회).
  ///
  /// blaze 강도(0~1)를 **3밴드**로 양자화한다(2026-06-02 '약→강 점진' 재적용) —
  /// 점화 직후엔 light로 약하게 시작해, 화력이 오르면 medium을 거쳐, 후반·말미
  /// 정점 구간(≥0.70 또는 spikeHeavy)에서 heavy로 묵직해진다. 파쇄기 [_grindPulse]
  /// (medium 바닥)와 달리 태우기는 light 바닥을 허용해 '서서히 타오르는' 점진감을 낸다.
  /// (HapticFeedback의 천장은 heavyImpact. 더 센 '연속' 진동은 Core Haptics 필요.)
  void _blazePulse(double intensity, {bool spikeHeavy = false}) {
    final level = (intensity >= 0.70 || spikeHeavy)
        ? HapticLevel.heavy
        : intensity >= 0.42
            ? HapticLevel.medium
            : HapticLevel.light;
    fire(level, throttle: false);
  }

  // ── 종이비행기 비행(flight) 전용 햅틱 ───────────────────────────────
  // 명세 §5.1 pressHum 계열. 파쇄기 [startShredGrind]·태우기 [startBurnBlaze]의
  // **형제** 드라이버지만, 둘과 정반대 캐릭터다 — grind/blaze가 'medium~heavy로
  // 고조하는 묵직한 연속'이라면, flight는 '진공/공중 활공'의 **가볍고 일정하게
  // 이어지는 hum**이다. light를 바닥으로 깔고(heavy로 치지 않음), 고조 곡선 없이
  // 등속 활공감을 유지한다. '공기 흐름'용 아주 미세한 강도/간격 변조만 얹는다.
  //
  // ⚠️ 연속 진동은 OS 네이티브 미배선 → 짧은 임팩트를 타이머로 반복하는
  // **근사**가 전부다. 실제 '진공처럼 매끄럽게 이어지는 hum' 손맛 튜닝은
  // 실기기에서만 검증 가능. 미지원/웹에서는 [fire]가 HapticFeedback 무음 통과
  // → 예외 없이 무동작(§4 폴백).

  /// 종이비행기 비행 중 연속 '진공/활공' hum(§5.1 pressHum). 던지는 순간 시작,
  /// 착지(완료)·dispose에서 [FlightHandle.stop].
  ///
  /// 비행 ~4초 동안 ~60ms 간격으로 가벼운 임팩트를 끊김 없이 반복해 '진공 속을
  /// 매끄럽게 활공하는' 느낌을 흉내낸다. grind/blaze와 달리 **고조 곡선이 없다**
  /// — 등속 활공이라 강도가 일정하다. 바닥은 light이고, 너무 약해 실기기에서
  /// 안 느껴지는 걸 막으려 4~5펄스마다 medium 1발을 섞어 '존재감 있는 hum'으로
  /// 만든다(그 외엔 light). '공기 흐름'용 ±몇 ms 미세 간격 변조만 얹는다.
  ///
  /// 반환된 [FlightHandle.stop]을 **착지(완료)·화면 dispose에서 반드시 호출**한다
  /// (무한 진동·타이머 누수 방지). 안전장치로 시작 후 5초 자동 stop된다
  /// (비행 ~4초보다 길게 — 호출측 stop 누락 대비).
  FlightHandle startFlightHum() {
    final handle = FlightHandle._(this);
    handle._start();
    return handle;
  }

  /// [FlightHandle]이 1펄스 발사할 때 사용(throttle 우회).
  ///
  /// grind/blaze의 [_grindPulse]/[_blazePulse]와 **정반대 철학** — 묵직함이 아니라
  /// **가벼움**이 목표다. 기본은 light로 매끄럽게 깔고, 간헐 강조([accent]=true,
  /// 4~5펄스마다)일 때만 medium 1발로 '존재감 있는 진공 hum'을 만든다.
  /// heavy는 쓰지 않는다(고조 없는 등속 활공감).
  void _flightPulse({bool accent = false}) {
    fire(accent ? HapticLevel.medium : HapticLevel.light, throttle: false);
  }

  /// 폭죽 연쇄 팝(§5.4). 호출 즉시 내부 지연 타이머로 전체 시퀀스를 발사한다.
  ///
  /// 강한 1발(heavy+success 겹침) 후 흩어지는 다수 팝(medium/light)이 ~380ms에
  /// 걸쳐 잦아든다. 모두 `throttle:false`. 화면은 bursting 진입 순간 1회만 호출하고,
  /// 시각 폭죽과 같은 프레임에 호출하면 동기된다.
  ///
  /// 외부 상태를 참조하지 않으므로 화면이 도중에 dispose돼도 무해하다
  /// (엔진 싱글톤·짧은 시퀀스). 미지원/웹에서는 무음 통과.
  void burstPop() {
    // ms 시퀀스(bursting 진입=0 기준): §5.4 그대로.
    // 0ms: heavy + success(겹침) → 묵직한 임팩트 두께.
    fire(HapticLevel.heavy, throttle: false);
    fire(HapticLevel.success, throttle: false);
    // 흩어지는 팝들. 각 지연마다 1발씩(외부 상태 참조 없음).
    Future<void>.delayed(const Duration(milliseconds: 70),
        () => fire(HapticLevel.medium, throttle: false)); // 첫 흩어짐
    Future<void>.delayed(const Duration(milliseconds: 130),
        () => fire(HapticLevel.light, throttle: false));
    Future<void>.delayed(const Duration(milliseconds: 190),
        () => fire(HapticLevel.light, throttle: false));
    Future<void>.delayed(const Duration(milliseconds: 220),
        () => fire(HapticLevel.medium, throttle: false)); // sparkle 2차 동기
    Future<void>.delayed(const Duration(milliseconds: 300),
        () => fire(HapticLevel.light, throttle: false));
    Future<void>.delayed(const Duration(milliseconds: 380),
        () => fire(HapticLevel.light, throttle: false)); // 마지막 잔향
  }

  /// 3초 폭죽 피날레(파쇄기 완료). 호출 즉시 내부 지연 타이머로 ~3초에 걸친
  /// '팡! 팡팡!!' 연쇄 폭죽 진동을 발사한다.
  ///
  /// 진짜 폭죽처럼: 0ms에 큰 1발(heavy+success 겹침)로 터뜨린 뒤, ~3000ms까지
  /// 여러 폭죽 묶음을 staggered로 쏜다. 각 묶음 = heavy(또는 medium) 1발 + 30~60ms
  /// 간격으로 흩어지는 medium/light 2~4발('팡팡!!'). 묶음 사이는 ~250~500ms 불규칙
  /// 간격(폭죽 터지는 리듬)이고, 후반으로 갈수록 약간 성기게 잦아든다.
  ///
  /// 전부 `throttle:false`. **외부 상태를 참조하지 않으므로** 화면이 도중에
  /// dispose돼도 무해하다(엔진 싱글톤 + 짧은 독립 [Future.delayed] 타이머들).
  /// 파쇄기 화면이 bursting 완료 순간 1회 호출한다. 미지원/웹에서는 무음 통과.
  void fireworksFinale() {
    // 0ms: 큰 1발 — heavy+success 겹침으로 묵직한 두께의 첫 폭발.
    fire(HapticLevel.heavy, throttle: false);
    fire(HapticLevel.success, throttle: false);

    // 묶음 시작 시각(ms). ~3000ms까지, 후반으로 갈수록 간격을 벌려 잦아들게 한다.
    // 간격: 280 → 320 → 360 → 420 → 480 → 540ms (점점 성기게).
    const burstStartsMs = <int>[300, 620, 980, 1400, 1880, 2420];
    // 묶음별 흩어지는 잔폭죽 수(팡팡!! 2~4발) — 초반 풍성, 후반 절제.
    const scatterCounts = <int>[4, 3, 4, 3, 2, 2];
    // 묶음 리드 레벨: heavy/medium 교차(초반 강, 후반 약).
    const leadHeavy = <bool>[true, true, false, true, false, false];

    for (var b = 0; b < burstStartsMs.length; b++) {
      final start = burstStartsMs[b];
      final lead = leadHeavy[b] ? HapticLevel.heavy : HapticLevel.medium;
      // 묶음 리드 1발(팡!).
      Future<void>.delayed(
        Duration(milliseconds: start),
        () => fire(lead, throttle: false),
      );
      // 흩어지는 잔폭죽(팡팡!!): 30~60ms 간격으로 medium/light 교차.
      final n = scatterCounts[b];
      for (var s = 0; s < n; s++) {
        // 30~60ms 누적 간격(s마다 35+조금씩 벌어짐).
        final offset = start + 35 + s * (30 + (s % 2) * 18);
        final level = s.isEven ? HapticLevel.light : HapticLevel.medium;
        Future<void>.delayed(
          Duration(milliseconds: offset),
          () => fire(level, throttle: false),
        );
      }
    }
  }

  // ── 보석함(jewel box) 심장박동 전용 햅틱 ──────────────────────────
  // 보석함 후광 펄스 구간(~3.5s)의 '심장박동' 연속 햅틱. 파쇄기 [startShredGrind]·
  // 태우기 [startBurnBlaze]의 **형제** 드라이버이지만, 저들이 '점점 강해지는 모터/
  // 화력 고조 곡선'인 것과 달리 이쪽은 **일정한 lub-dub 두 박자(~72bpm)** 를 따뜻·
  // 부드럽게 반복한다. heavy를 쓰지 않고 medium(lub)→light(dub)로 폰 전반에 묵직히
  // 퍼지는 안정 심박을 흉내낸다(기존 드라이버는 그대로 유지).
  //
  // ⚠️ 연속/패턴 진동은 OS 네이티브 미배선 → 짧은 임팩트를 타이머로 반복하는
  // **근사**가 전부다. '따뜻하게 번지는 심장박동'의 실제 손맛(특히 dub의 부드러운
  // 여운·폰 전반 확산감)은 실기기에서만 검증 가능. 미지원/웹에서는 [fire]가
  // HapticFeedback 무음 통과 → 예외 없이 무동작(§9 폴백).

  /// 보석함 후광 펄스 구간의 '심장박동' 연속 햅틱(따뜻·부드럽게 폰 전반으로).
  ///
  /// 후광 등장 시 시작, 완료 멘트/dispose에서 [HeartbeatHandle.stop]으로 멈춘다.
  /// lub(medium)→130ms→dub(light)→620ms 휴지를 한 박동(≈750~850ms, 약 72bpm)으로
  /// 무한 반복한다 — 따뜻한 안정 심박. heavy는 쓰지 않는다(날카로움 금지). 너무
  /// 기계적이지 않도록 박동 주기에 ±20~30ms 미세 변조(생체 리듬)를 얹는다.
  ///
  /// **완료 멘트/화면 dispose에서 반드시 [HeartbeatHandle.stop]을 호출**해야 무한
  /// 진동·타이머 누수를 막는다. [stop]은 중복 호출해도 안전하다(idempotent). 안전장치로
  /// 시작 후 ~8초 경과 시 자동 [stop]된다(후광 구간 ~3.5s보다 길게 — stop 누락 대비).
  HeartbeatHandle startHeartbeat({
    Duration safety = const Duration(seconds: 8),
  }) {
    final handle = HeartbeatHandle._(this, safety);
    handle._start();
    return handle;
  }

  /// [HeartbeatHandle]이 lub/dub 1박을 발사할 때 사용(throttle 우회).
  ///
  /// lub=medium(폰 전반으로 묵직히 퍼지는 첫 박), dub=light(부드러운 둘째 박).
  /// **heavy 미사용** — 따뜻·부드러움이 핵심이라 날카로운 단계는 쓰지 않는다.
  /// (light만으론 '폰 전반' 확산감이 약해 lub은 medium으로 둔다. 더 풍부한 연속
  /// 심박은 Core Haptics 필요.)
  void _heartPulse({required bool isLub}) {
    fire(isLub ? HapticLevel.medium : HapticLevel.light, throttle: false);
  }

  // ── 종이비행기 하늘 부유(skyFloat) 전용 햅틱 ────────────────────────
  // 종이비행기 완료 하늘 씬의 '두둥실 떠 있는' 연속 햅틱. 파쇄기 [startShredGrind]·
  // 태우기 [startBurnBlaze]·비행 [startFlightHum]·심박 [startHeartbeat]의 **형제**
  // 드라이버지만, 이들 중 **가장 가볍고 느린** 캐릭터다 —
  //   · grind: medium~heavy staccato(묵직·잘게 끊김),
  //   · blaze: light→heavy 고조(점점 세짐),
  //   · flight: light 등속 hum(가볍지만 ~60ms로 촘촘·일정),
  //   · heartbeat: lub-dub 두 박(medium→light, ~72bpm 또렷),
  //   · skyFloat: **light/selection을 ~500~800ms 간격으로 성기게** 발사하고,
  //     긴 sin swell(주기 ~3s)로 강도·간격이 부드럽게 오르내려 '무중력으로
  //     떠올랐다 가라앉는 두둥실'을 만든다. heavy 절대 금지, medium은 swell
  //     정점에서만 아주 가끔. 비행 hum보다 훨씬 성기고 느린 부유감.
  //
  // ⚠️ 연속/패턴 진동은 OS 네이티브 미배선 → 짧은 임팩트의 타이머 반복 **근사**가
  // 전부다. '무중력 부유'의 실제 손맛(부드러운 swell·아주 약한 펄스)은 실기기에서만
  // 검증 가능. 미지원/웹에서는 [fire]가 HapticFeedback 무음 통과 → 예외 없이 무동작.

  /// 종이비행기 완료 하늘 씬의 '두둥실 떠 있는' 연속 햅틱. 하늘 씬 진입 시 시작,
  /// '처음으로' 탭/dispose에서 [SkyFloatHandle.stop].
  ///
  /// 아주 가벼운 펄스(주로 light, 가끔 더 약한 selection)를 **느리고 성기게**
  /// (~500~800ms 간격) 발사하되, 긴 sin swell(주기 ~3s)로 강도·간격을 부드럽게
  /// 오르내린다 — swell이 높을 때(떠오름) 간격 ~500ms·light, 낮을 때(가라앉음)
  /// 간격 ~800ms·selection. heavy는 절대 쓰지 않고, medium은 swell 정점에서만
  /// 아주 가끔 섞어 '두둥실' 부유감을 낸다. 전부 `throttle:false`.
  ///
  /// 하늘에 오래 머물 수 있어 [safety](기본 12s, 화면이 더 길게 주입)로 stop 누락에
  /// 대비한다. 반환된 [SkyFloatHandle.stop]을 **'처음으로' 탭·화면 dispose에서 반드시
  /// 호출**해야 무한 진동·타이머 누수를 막는다. [stop]은 중복 호출해도 안전하다.
  SkyFloatHandle startSkyFloat({Duration safety = const Duration(seconds: 12)}) {
    final handle = SkyFloatHandle._(this, safety);
    handle._start();
    return handle;
  }

  /// [SkyFloatHandle]이 1펄스 발사할 때 사용(throttle 우회).
  ///
  /// grind/blaze/heartbeat와 정반대로 **가장 가벼움**이 목표다. 바닥은 selection
  /// (가라앉음, 가장 약함), swell이 오르면 light(떠오름), 정점에서만 아주 가끔
  /// medium([peak]=true)을 섞는다. **heavy는 절대 쓰지 않는다**(무중력 부유라
  /// 날카로운 단계 금지).
  void _skyFloatPulse({required bool light, bool peak = false}) {
    fire(
      peak
          ? HapticLevel.medium
          : light
              ? HapticLevel.light
              : HapticLevel.selection,
      throttle: false,
    );
  }

  // ── P3 신규: 의식별 타임라인/스텝 큐 빌더 ────────────────────────
  // playTimeline(controller, cues)에 그대로 넣을 수 있는 List<HapticCue> 생성.

  /// 태우기(burn) 진행 타임라인 큐.
  ///
  /// 진행도 0→1을 따라 **비감소(앞 큐 ≤ 뒤 큐)** 로 강해진다 — 불이 번지며
  /// 가속하는 느낌. 시작은 가장 약하고(light) 끝은 가장 강하다(heavy).
  /// 큐 5개. `playTimeline`이 각 지점에서 1회씩 발사한다.
  ///
  /// 완료(전소) 직후의 '잦아드는 잔불' 마무리는 이 타임라인이 아니라
  /// 화면의 onComplete에서 [softSuccess]를 호출해 표현한다(아래 notes 참조).
  static List<HapticCue> burnTimeline() => const [
        HapticCue(0.0, HapticLevel.light), // 불씨가 옮겨붙음
        HapticCue(0.25, HapticLevel.light), // 가장자리부터 천천히
        HapticCue(0.5, HapticLevel.medium), // 번지기 시작
        HapticCue(0.75, HapticLevel.medium), // 활활
        HapticCue(1.0, HapticLevel.heavy), // 전소 직전 최고조
      ];

  /// 종이비행기 접기 단계 큐(현행 동작 호환): light·light·medium 3큐.
  /// 마지막 접힘이 가장 단단한 느낌(medium)이 되도록 비감소 구성.
  static List<HapticCue> foldStepCue() => const [
        HapticCue(0.2, HapticLevel.light), // 첫 접힘
        HapticCue(0.5, HapticLevel.light), // 두 번째 접힘
        HapticCue(0.85, HapticLevel.medium), // 마지막 단단히 눌러 접기
      ];

  // ── 타임라인 햅틱 ────────────────────────────────────────────────
  // 애니메이션 컨트롤러(0~1)에 cue 목록을 붙여 진행도가 지점을 넘을 때 발사.

  /// [controller] 한 번 실행 동안 [cues]의 각 (at, level)을 1회씩 발사.
  /// 반환된 함수를 dispose 시 호출하면 리스너가 제거된다.
  VoidCallback playTimeline(
    AnimationController controller,
    List<HapticCue> cues,
  ) {
    final fired = <int>{};
    void listener() {
      final t = controller.value;
      for (var i = 0; i < cues.length; i++) {
        if (t >= cues[i].at && fired.add(i)) {
          fire(cues[i].level, throttle: false);
        }
      }
    }

    controller.addListener(listener);
    return () => controller.removeListener(listener);
  }
}

/// 타임라인 햅틱 큐: 진행도 [at](0~1)에서 [level] 발사.
class HapticCue {
  const HapticCue(this.at, this.level);
  final double at;
  final HapticLevel level;
}

/// [Haptics.rumble]이 반환하는 연속 진동 제어 핸들.
///
/// 시작 시점에 타이머가 돌기 시작하고, [stop]을 호출하면 즉시 멈춘다.
/// **드래그 종료·화면 dispose에서 반드시 [stop]을 호출**해야 무한 진동·
/// 타이머 누수를 막을 수 있다. [stop]은 중복 호출해도 안전하다(idempotent).
class RumbleHandle {
  RumbleHandle._(this._engine, double intensity)
      : _intensity = intensity.clamp(0.0, 1.0);

  final Haptics _engine;
  double _intensity;
  Timer? _timer;
  bool _stopped = false;

  /// 강도(0~1)에 따라 펄스 간격을 매핑: 강할수록 촘촘하게(30~60ms).
  Duration get _interval {
    final ms = (60 - _intensity * 30).round().clamp(30, 60);
    return Duration(milliseconds: ms);
  }

  void _start(Duration total) {
    if (_stopped) return;
    _engine._rumblePulse(_intensity); // 즉시 첫 펄스(반응 지연 최소화)
    _timer = Timer.periodic(_interval, (_) {
      _engine._rumblePulse(_intensity);
    });
    // 안전장치: total 경과 시 자동 종료(stop 누락 대비).
    Future<void>.delayed(total, stop);
  }

  /// 실시간 강도 갱신(예: 드래그 속도 → 진동 세기). 간격도 재적용한다.
  void setIntensity(double v) {
    if (_stopped) return;
    _intensity = v.clamp(0.0, 1.0);
    _timer?.cancel();
    _timer = Timer.periodic(_interval, (_) {
      _engine._rumblePulse(_intensity);
    });
  }

  /// 연속 진동 중지(+타이머 해제). 중복 호출 안전.
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }

  /// [stop]의 별칭 — dispose 흐름에서 의도가 드러나도록.
  void dispose() => stop();
}

/// [Haptics.startShredGrind]가 반환하는 파쇄기 연속 그라인드 제어 핸들(§5.3).
///
/// [RumbleHandle]의 형제격이지만, grinding 고유의 '강도 고조 곡선(0.60→1.0)·
/// staccato 펄스 묶음(3발 tight ~22ms + 공백 ~100ms, 말미 더 촘촘)·모터 지터'를
/// 내장한다. 시작 시점에 타이머가 돌며, [stop]을 호출하면 즉시 멈춘다.
///
/// **bursting 진입·화면 dispose에서 반드시 [stop]을 호출**해야 무한 진동·타이머
/// 누수를 막는다. [stop]은 중복 호출해도 안전하다(idempotent). 안전장치로 시작
/// 후 [_safety] 경과 시 자동 [stop]된다(호출측 stop 누락 대비).
class GrindHandle {
  GrindHandle._(this._engine);

  final Haptics _engine;

  /// 그라인드 명목 길이(§4.2 GRIND_DURATION과 동일한 3초).
  static const Duration _duration = Duration(milliseconds: 3000);

  /// stop 누락 대비 자동 종료 시한(명목 3초 + 여유).
  static const Duration _safety = Duration(milliseconds: 4000);

  Timer? _timer;
  bool _stopped = false;

  /// staccato 묶음 내 펄스 위치(0..[_burstLen]-1). 묶음 끝이면 다음은 공백 간격.
  int _burstStep = 0;

  /// 한 묶음당 펄스 수(짧은 펄스 3발 → 공백 반복으로 '잘게 끊기는' 질감).
  static const int _burstLen = 3;

  /// 시작 시각 — setProgress 미호출 시 자체 경과시간으로 기본 곡선을 만든다.
  final Stopwatch _watch = Stopwatch();

  /// 외부 주입 진행도(0~1). null이면 [_watch] 경과 기반 기본 곡선을 쓴다.
  double? _externalT;

  void _start() {
    if (_stopped) return;
    _watch.start();
    _engine._grindPulse(_curveIntensity()); // 즉시 첫 펄스(반응 지연 최소화)
    _burstStep = (_burstStep + 1) % _burstLen;
    _schedule();
    // 안전장치: 시한 경과 시 자동 종료.
    Future<void>.delayed(_safety, stop);
  }

  /// 현재 진행도(0~1) — 주입값 우선, 없으면 경과시간 기반.
  double _progress() {
    final ext = _externalT;
    if (ext != null) return ext.clamp(0.0, 1.0);
    return (_watch.elapsedMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
  }

  /// 진행도 t(0~1) → 강도. §5.3 키프레임을 선형 보간한 0.60→1.0 상승 곡선에
  /// '도는 모터'용 미세 sin 변조(±0.06)를 얹는다.
  double _curveIntensity() {
    final t = _progress();
    // 키프레임(실기기 강화 2026-06-01): 0.0→0.60, 0.33→0.72, 0.66→0.85,
    // 0.80→0.93, 1.0→1.00. medium에서 출발해 빠르게 heavy로 올라 폭죽 직전 최고조.
    final double base;
    if (t < 0.33) {
      base = _lerp(0.60, 0.72, t / 0.33);
    } else if (t < 0.66) {
      base = _lerp(0.72, 0.85, (t - 0.33) / 0.33);
    } else if (t < 0.80) {
      base = _lerp(0.85, 0.93, (t - 0.66) / 0.14);
    } else {
      base = _lerp(0.93, 1.00, (t - 0.80) / 0.20);
    }
    // 모터 회전감: 약 3Hz로 강도를 흔든다(t를 위상으로 사용).
    final wobble = 0.06 * math.sin(t * 2 * math.pi * 3);
    return (base + wobble).clamp(0.0, 1.0);
  }

  /// 진행도/묶음 위치에 따른 다음 펄스 간격. **staccato**(잘게 끊김): 묶음 안
  /// (`inBurst`)이면 짧게 붙이고(~22ms, 말미 18ms), 묶음 끝이면 공백을 둔다
  /// (~100ms, 말미 78ms). '도는 모터'감을 위해 ±몇 ms 지터를 얹는다.
  Duration _nextInterval() {
    final t = _progress();
    final tail = t >= 0.9;
    // _start/_schedule에서 발사 직후 _burstStep을 증가시키므로, 지금 값이
    // _burstLen-1 미만이면 아직 묶음 안(다음도 tight) — 아니면 묶음 끝(다음은 gap).
    final inBurst = _burstStep < _burstLen - 1;
    final baseMs = inBurst
        ? (tail ? 18 : 22) // 묶음 내: 짧게 연달아
        : (tail ? 78 : 100); // 묶음 사이: 공백
    // 경과 us 기반 의사난수 지터 — 외부 의존 없이 결정적·가벼움.
    final jitter = (_watch.elapsedMicroseconds % 9) - 4; // -4..+4
    final lo = inBurst ? 14 : 60;
    final hi = inBurst ? 30 : 130;
    final ms = (baseMs + jitter).clamp(lo, hi);
    return Duration(milliseconds: ms);
  }

  /// 매 펄스마다 간격을 재계산해 1발 발사하고 다음 펄스를 예약(가변 간격, staccato).
  void _schedule() {
    if (_stopped) return;
    _timer = Timer(_nextInterval(), () {
      if (_stopped) return;
      final t = _progress();
      // 최말미(≥0.9) 순간엔 heavy를 가끔 섞어 폭죽 직전 텐션.
      _engine._grindPulse(_curveIntensity(), spikeHeavy: t >= 0.9);
      _burstStep = (_burstStep + 1) % _burstLen;
      _schedule();
    });
  }

  /// 매 프레임 진행도(0~1) 주입 — 강도 고조·말미 촘촘함을 화면 컨트롤러에 동조.
  /// 선택 사항(미호출 시 자체 경과시간 기반 기본 곡선으로 동작).
  void setProgress(double t) {
    if (_stopped) return;
    _externalT = t.clamp(0.0, 1.0);
    // 강도/간격은 다음 펄스 예약 시점에 자동 반영되므로 타이머 재설정 불필요.
  }

  /// 연속 그라인드 중지(+타이머 해제). 중복 호출 안전.
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    _watch.stop();
  }

  static double _lerp(double a, double b, double t) =>
      a + (b - a) * t.clamp(0.0, 1.0);
}

/// [Haptics.startBurnBlaze]가 반환하는 태우기 연속 연소 제어 핸들(§4 햅틱).
///
/// [GrindHandle]의 **형제**격이지만, 태우기 고유의 '아래→위 화력 점진 곡선
/// (0.28→1.0, 약→강)·말미 촘촘함(35ms)·불 일렁임 지터'를 내장한다. 시작 시점에 ~45ms
/// 타이머가 돌며, [stop]을 호출하면 즉시 멈춘다.
///
/// **전소(softSuccess 직전)·화면 dispose에서 반드시 [stop]을 호출**해야 무한
/// 진동·타이머 누수를 막는다. [stop]은 중복 호출해도 안전하다(idempotent).
/// 안전장치로 시작 후 [_safety] 경과 시 자동 [stop]된다(호출측 stop 누락 대비).
///
/// ⚠️ 연속 진동은 OS 네이티브 미배선 → 짧은 임팩트의 타이머 반복 **근사**가
/// 전부다. '점점 강해지는 연속 진동' 손맛 튜닝은 실기기에서만 검증 가능.
class BlazeHandle {
  BlazeHandle._(this._engine);

  final Haptics _engine;

  /// 연소 명목 길이(화면 `_kBurnDuration`과 동일한 4.5초).
  static const Duration _duration = Duration(milliseconds: 4500);

  /// stop 누락 대비 자동 종료 시한(명목 4.5초 + 여유).
  static const Duration _safety = Duration(milliseconds: 5500);

  Timer? _timer;
  bool _stopped = false;

  /// 시작 시각 — setProgress 미호출 시 자체 경과시간으로 기본 곡선을 만든다.
  final Stopwatch _watch = Stopwatch();

  /// 외부 주입 진행도(0~1). null이면 [_watch] 경과 기반 기본 곡선을 쓴다.
  double? _externalT;

  void _start() {
    if (_stopped) return;
    _watch.start();
    _engine._blazePulse(_curveIntensity()); // 즉시 첫 펄스(점화 반응 지연 최소화)
    _schedule();
    // 안전장치: 시한 경과 시 자동 종료.
    Future<void>.delayed(_safety, stop);
  }

  /// 현재 진행도(0~1) — 주입값 우선, 없으면 경과시간 기반.
  double _progress() {
    final ext = _externalT;
    if (ext != null) return ext.clamp(0.0, 1.0);
    return (_watch.elapsedMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
  }

  /// 진행도 t(0~1) → 강도. §4(햅틱) 키프레임을 선형 보간한 0.28→1.0 상승 곡선에
  /// '타오르는 불 일렁임'용 미세 sin 변조(±0.05)를 얹는다.
  ///
  /// '약→강 점진' 재적용(2026-06-02) — 점화 직후를 낮게(0.28, light 대역) 출발시켜
  /// 서서히 타오르다 전소 직전 정점(1.00, heavy)으로 올린다. _blazePulse 3밴드
  /// (light<0.42≤medium<0.70≤heavy)와 맞물려 light→medium→heavy로 자연 점진한다.
  double _curveIntensity() {
    final t = _progress();
    // 키프레임('약→강 점진'): 0.0→0.28, 0.4→0.55, 0.7→0.80, 1.0→1.00.
    // light에서 출발해 medium(≥0.42)·heavy(≥0.70)로 올라 전소 직전 최고조.
    // 키프레임 상향(2026-06-02 '강도 최고치'): 상반부부터 heavy(≥0.70)에 도달해
    // 정점까지 최고 강도를 유지한다. light에서 출발해 빠르게 heavy로 치솟음.
    final double base;
    if (t < 0.4) {
      base = _lerp(0.30, 0.60, t / 0.4);
    } else if (t < 0.7) {
      base = _lerp(0.60, 0.90, (t - 0.4) / 0.3);
    } else {
      base = _lerp(0.90, 1.00, (t - 0.7) / 0.3);
    }
    // 불 일렁임: 약 4.5Hz로 강도를 흔든다(t를 위상으로 사용 — '타오르는 떨림').
    final wobble = 0.05 * math.sin(t * 2 * math.pi * 4.5);
    return (base + wobble).clamp(0.0, 1.0);
  }

  /// 진행도에 따른 펄스 간격. 사용자 피드백(2026-06-02 '진동 빈도 점점 세게'):
  /// 불이 위로 화르륵 오를수록 간격이 **연속적으로 짧아진다** — 시작 ~55ms(성김)
  /// → 정점 ~16ms(맹렬히 촘촘). '점점 빈도가 세지는' 고조감. ±6ms 지터.
  Duration _nextInterval() {
    final t = _progress();
    final baseMs = _lerp(55, 16, t); // 진행도 따라 간격 단조 감소(빈도 상승).
    final jitter = (_watch.elapsedMicroseconds % 13) - 6; // -6..+6
    final ms = (baseMs + jitter).clamp(12.0, 60.0).round();
    return Duration(milliseconds: ms);
  }

  /// 매 펄스마다 간격을 재계산해 1발 발사하고 다음 펄스를 예약(가변 간격).
  void _schedule() {
    if (_stopped) return;
    _timer = Timer(_nextInterval(), () {
      if (_stopped) return;
      final t = _progress();
      // 상반부 정점 구간(≥0.75)은 heavy 상시 — '강도 최고치'로 치솟아 유지.
      _engine._blazePulse(_curveIntensity(), spikeHeavy: t >= 0.75);
      _schedule();
    });
  }

  /// 매 프레임 진행도(0~1) 주입 — 화력 고조·말미 촘촘함을 화면 `_burnCtrl`에 동조.
  /// 선택 사항(미호출 시 자체 경과시간 기반 기본 곡선으로 동작).
  void setProgress(double t) {
    if (_stopped) return;
    _externalT = t.clamp(0.0, 1.0);
    // 강도/간격은 다음 펄스 예약 시점에 자동 반영되므로 타이머 재설정 불필요.
  }

  /// 연속 연소 중지(+타이머 해제). 중복 호출 안전.
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    _watch.stop();
  }

  /// [stop]의 별칭 — dispose 흐름에서 의도가 드러나도록(계약 §4).
  void dispose() => stop();

  static double _lerp(double a, double b, double t) =>
      a + (b - a) * t.clamp(0.0, 1.0);
}

/// [Haptics.startFlightHum]이 반환하는 종이비행기 비행 hum 제어 핸들(§5.1).
///
/// [GrindHandle]/[BlazeHandle]의 **형제**격이지만 캐릭터가 정반대다 — grind/blaze가
/// 'medium~heavy로 고조하는 묵직한 연속'이라면, flight는 '진공/공중 활공'의
/// **가볍고 일정하게 이어지는 hum**이다. 고조 곡선·Stopwatch 진행도가 없고
/// (등속 활공이라 강도 곡선이 필요 없다), 바닥 light에 4~5펄스마다 medium 1발만
/// 섞는다. 시작 시점에 ~60ms 타이머가 돌며, [stop]을 호출하면 즉시 멈춘다.
///
/// **착지(완료)·화면 dispose에서 반드시 [stop]을 호출**해야 무한 진동·타이머
/// 누수를 막는다. [stop]은 중복 호출해도 안전하다(idempotent). 안전장치로 시작
/// 후 [_safety](5초) 경과 시 자동 [stop]된다(비행 ~4초보다 길게 — stop 누락 대비).
///
/// ⚠️ 연속 진동은 OS 네이티브 미배선 → 짧은 임팩트의 타이머 반복 **근사**가
/// 전부다. '진공처럼 매끄럽게 이어지는 hum' 손맛 튜닝은 실기기에서만 검증 가능.
class FlightHandle {
  FlightHandle._(this._engine);

  final Haptics _engine;

  /// stop 누락 대비 자동 종료 시한. 비행 ~4초보다 길게 잡아 정상 비행을 가리지 않되,
  /// 호출측 stop 누락 시 무한 진동을 막는다.
  static const Duration _safety = Duration(milliseconds: 5000);

  /// hum 기본 펄스 간격(~60ms). grind/blaze(~45ms)보다 성기게 잡아 '촘촘한 모터'가
  /// 아니라 '매끄럽게 이어지는 가벼운 활공'으로 들리게 한다.
  static const int _baseMs = 60;

  /// 이 펄스마다 한 번 medium을 섞어 '존재감 있는 진공 hum'을 만든다(그 외 light).
  static const int _accentEvery = 5;

  Timer? _timer;
  bool _stopped = false;

  /// 발사한 펄스 카운터 — accent(중간 medium) 주기 판정·미세 간격 변조의 위상으로 쓴다.
  int _tick = 0;

  void _start() {
    if (_stopped) return;
    _engine._flightPulse(accent: false); // 즉시 첫 펄스(던지는 순간 반응 지연 최소화)
    _tick = 1;
    _schedule();
    // 안전장치: 시한 경과 시 자동 종료.
    Future<void>.delayed(_safety, stop);
  }

  /// 다음 펄스 간격. 기본 ~60ms에 '공기 흐름'용 ±4ms 미세 변조만 얹는다(고조 없음 —
  /// 등속 활공이라 간격도 거의 일정하게 유지). 카운터를 위상으로 써 외부 의존 없이
  /// 결정적·가볍게 흔든다.
  Duration _nextInterval() {
    // 카운터 기반 의사난수 변조(±4ms) — 미세하게만, 매끄러운 일정감 유지.
    final jitter = (_tick * 7 % 9) - 4; // -4..+4
    final ms = (_baseMs + jitter).clamp(48, 72);
    return Duration(milliseconds: ms);
  }

  /// 매 펄스마다 간격을 재계산해 1발 발사하고 다음 펄스를 예약(가변 간격).
  void _schedule() {
    if (_stopped) return;
    _timer = Timer(_nextInterval(), () {
      if (_stopped) return;
      // 4~5펄스마다 medium 1발로 존재감 강조, 그 외엔 light로 매끄럽게.
      final accent = _tick % _accentEvery == 0;
      _engine._flightPulse(accent: accent);
      _tick++;
      _schedule();
    });
  }

  /// 비행 hum 중지(+타이머 해제). 중복 호출 안전(idempotent).
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }

  /// [stop]의 별칭 — dispose 흐름에서 의도가 드러나도록(계약).
  void dispose() => stop();
}

/// [Haptics.startHeartbeat]가 반환하는 보석함 '심장박동' 연속 햅틱 제어 핸들.
///
/// [GrindHandle]/[BlazeHandle]의 **형제**격이지만, 저들의 '점점 강해지는 고조
/// 곡선'과 달리 이쪽은 **일정한 lub-dub 두 박자(~72bpm)** 를 따뜻·부드럽게 반복한다.
/// 시작 시점에 첫 lub이 즉시 발사되고, 이후 각 박동은 직전 박동 시작에서 한 주기 뒤로
/// 재귀 예약된다(lub → 130ms 뒤 dub 1발 예약 → 다음 박동을 주기 후 예약).
///
/// **완료 멘트·화면 dispose에서 반드시 [stop]을 호출**해야 무한 진동·타이머 누수를
/// 막는다. [stop]은 중복 호출해도 안전하다(idempotent). 안전장치로 시작 후 [_safety]
/// 경과 시 자동 [stop]된다(호출측 stop 누락 대비).
///
/// ⚠️ 연속/패턴 진동은 OS 네이티브 미배선 → 짧은 임팩트의 타이머 반복 **근사**가
/// 전부다. '따뜻하게 폰 전반으로 번지는' 심박의 실제 손맛은 실기기에서만 검증 가능.
class HeartbeatHandle {
  HeartbeatHandle._(this._engine, this._safety);

  final Haptics _engine;

  /// lub→dub 간격(수축기). 짧고 또렷한 '두-근'의 앞 박.
  static const Duration _lubToDub = Duration(milliseconds: 130);

  /// 한 박동의 기본 주기(~72bpm). lub(0) → dub(130) → 휴지(~620) ≈ 830ms.
  /// 자체 미세 변조(±25ms)를 얹어 기계적이지 않은 생체 리듬을 만든다.
  static const int _periodMs = 830;

  /// stop 누락 대비 자동 종료 시한(생성 시 주입). 보석함은 '처음으로' 탭까지
  /// 지속이라 길게 잡는다 — 화면 dispose가 항상 stop하므로 무한 진동 위험은 없다.
  final Duration _safety;

  /// 다음 박동(재귀)·dub 발사용 타이머. 매 박동마다 갱신된다.
  Timer? _beatTimer;
  Timer? _dubTimer;
  bool _stopped = false;

  /// 박동 시작 시각 — 주기 미세 변조용 의사난수 시드(외부 의존 없이 결정적·가벼움).
  final Stopwatch _watch = Stopwatch();

  void _start() {
    if (_stopped) return;
    _watch.start();
    _beat(); // 즉시 첫 박동(반응 지연 최소화)
    // 안전장치: 시한 경과 시 자동 종료.
    Future<void>.delayed(_safety, stop);
  }

  /// 한 박동: lub 즉시 발사 → 130ms 뒤 dub 1발 예약 → 한 주기 뒤 다음 박동 재귀 예약.
  void _beat() {
    if (_stopped) return;
    _engine._heartPulse(isLub: true); // lub: medium, 폰 전반으로 묵직히
    _dubTimer = Timer(_lubToDub, () {
      if (_stopped) return;
      _engine._heartPulse(isLub: false); // dub: light, 부드러운 둘째 박
    });
    _beatTimer = Timer(Duration(milliseconds: _nextPeriodMs()), _beat);
  }

  /// 다음 박동까지의 주기(ms). 기본 [_periodMs]에 ±25ms 미세 변조를 얹어
  /// 너무 정확한 메트로놈이 아닌 살아있는 심박처럼 흔든다.
  int _nextPeriodMs() {
    // 경과 마이크로초 기반 의사난수 변조(-25..+25ms) — 결정적·가벼움.
    final wobble = (_watch.elapsedMicroseconds % 51) - 25; // -25..+25
    return (_periodMs + wobble).clamp(700, 950);
  }

  /// 심장박동 중지(+모든 예약 타이머 해제). 중복 호출 안전(idempotent).
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _beatTimer?.cancel();
    _beatTimer = null;
    _dubTimer?.cancel();
    _dubTimer = null;
    _watch.stop();
  }

  /// [stop]의 별칭 — dispose 흐름에서 의도가 드러나도록.
  void dispose() => stop();
}

/// [Haptics.startSkyFloat]가 반환하는 종이비행기 하늘 '두둥실 부유' 제어 핸들.
///
/// [GrindHandle]/[BlazeHandle]/[FlightHandle]/[HeartbeatHandle]의 **형제**격이지만,
/// 이들 중 **가장 가볍고 느린** 캐릭터다 — grind/blaze의 묵직한 고조도, flight의
/// 촘촘한 등속 hum도, heartbeat의 또렷한 두 박도 아니다. 아주 약한 펄스(light/
/// selection)를 ~500~800ms로 성기게 발사하되, 긴 sin swell(주기 [_swellMs]≈3s)로
/// 강도·간격을 부드럽게 오르내려 '무중력으로 떠올랐다 가라앉는 두둥실'을 만든다.
///
/// 시작 시점에 첫 펄스가 즉시 발사되고, 매 펄스마다 swell 위상에 따라 다음 펄스를
/// 재예약한다(가변 간격). [stop]을 호출하면 즉시 멈춘다.
///
/// **'처음으로' 탭·화면 dispose에서 반드시 [stop]을 호출**해야 무한 진동·타이머
/// 누수를 막는다. [stop]은 중복 호출해도 안전하다(idempotent). 안전장치로 시작 후
/// [_safety](생성 시 주입, 기본 12s — 하늘에 오래 머물 수 있어 길게) 경과 시 자동
/// [stop]된다(호출측 stop 누락 대비).
///
/// ⚠️ 연속/패턴 진동은 OS 네이티브 미배선 → 짧은 임팩트의 타이머 반복 **근사**가
/// 전부다. '무중력 부유'의 실제 손맛(부드러운 swell·아주 약한 펄스)은 실기기에서만
/// 검증 가능.
class SkyFloatHandle {
  SkyFloatHandle._(this._engine, this._safety);

  final Haptics _engine;

  /// stop 누락 대비 자동 종료 시한(생성 시 주입). 하늘 씬은 '처음으로' 탭까지
  /// 지속이라 길게 잡는다 — 화면 dispose가 항상 stop하므로 무한 진동 위험은 없다.
  final Duration _safety;

  /// swell 한 주기 길이(≈3s) — 강도·간격이 오르내리는 '떠올랐다 가라앉는' 호흡.
  static const int _swellMs = 3000;

  /// swell 정점(떠오름) 펄스 간격 — 성기게(느리게).
  static const int _intervalPeakMs = 500;

  /// swell 저점(가라앉음) 펄스 간격 — 더 성기게(가장 느리게).
  static const int _intervalTroughMs = 800;

  Timer? _timer;
  bool _stopped = false;

  /// swell 위상 기준 시각(경과로 sin 위상을 만든다). 외부 의존 없이 결정적·가벼움.
  final Stopwatch _watch = Stopwatch();

  void _start() {
    if (_stopped) return;
    _watch.start();
    _firePulse(); // 즉시 첫 펄스(하늘 씬 진입 반응 지연 최소화)
    _schedule();
    // 안전장치: 시한 경과 시 자동 종료.
    Future<void>.delayed(_safety, stop);
  }

  /// 현재 swell 값(0~1) — sin으로 부드럽게 오르내린다(0=가라앉음, 1=떠오름).
  double _swell() {
    final phase = (_watch.elapsedMilliseconds % _swellMs) / _swellMs; // 0~1
    // 0.5 - 0.5cos(2πφ) → φ=0에서 0(저점) 시작해 부드럽게 상승·하강.
    return 0.5 - 0.5 * math.cos(phase * 2 * math.pi);
  }

  /// 현재 swell에 따른 다음 펄스 간격. 떠오름(swell↑)일수록 촘촘(~500ms),
  /// 가라앉음(swell↓)일수록 성김(~800ms). swell이 sin이라 경계는 부드럽게 연결된다.
  /// '공중 부유'용 ±몇 ms 미세 변조만 얹어 너무 기계적이지 않게 한다.
  Duration _nextInterval() {
    final s = _swell();
    final baseMs = _intervalTroughMs + (_intervalPeakMs - _intervalTroughMs) * s;
    final jitter = (_watch.elapsedMicroseconds % 41) - 20; // -20..+20
    final ms = (baseMs + jitter).clamp(450.0, 850.0).round();
    return Duration(milliseconds: ms);
  }

  /// 현재 swell에 따라 1펄스 발사. 저점(swell<0.5)은 selection(가장 약함, 가라앉음),
  /// 그 이상은 light(떠오름). 정점(swell≥0.85)에서만 아주 가끔 medium을 섞는다
  /// — heavy는 절대 발사하지 않는다.
  void _firePulse() {
    final s = _swell();
    final peak = s >= 0.85 && (_watch.elapsedMilliseconds ~/ 100).isEven;
    _engine._skyFloatPulse(light: s >= 0.5, peak: peak);
  }

  /// 매 펄스마다 간격을 재계산해 1발 발사하고 다음 펄스를 예약(가변 간격, swell 동조).
  void _schedule() {
    if (_stopped) return;
    _timer = Timer(_nextInterval(), () {
      if (_stopped) return;
      _firePulse();
      _schedule();
    });
  }

  /// 두둥실 부유 중지(+타이머 해제). 중복 호출 안전(idempotent).
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    _watch.stop();
  }

  /// [stop]의 별칭 — dispose 흐름에서 의도가 드러나도록.
  void dispose() => stop();
}
