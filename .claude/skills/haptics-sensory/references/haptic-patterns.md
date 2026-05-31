# 햅틱 패턴 — 플랫폼별 구현 & 폴백 레퍼런스

> sensory-haptics가 패턴을 구현할 때 참조. 정본 표는 `docs/PRODUCT_SPEC.md` 5.1. 여기서는 구현 골격과 폴백 매핑을 다룬다.

## 목차
1. 패턴별 플랫폼 매핑
2. iOS Core Haptics 채널 골격
3. Android vibration 골격
4. 폴백 전략
5. 역량 감지 (graceful degradation)

---

## 1. 패턴별 플랫폼 매핑

| 패턴명 | 느낌 | iOS (Core Haptics) | Android (vibration) | 폴백 (HapticFeedback) |
|---|---|---|---|---|
| `tapPop` | 통 | transient, sharpness↑ | 단발 40ms / amp 128 | lightImpact |
| `pressHum` | 누름 지속 | continuous, intensity 가변 | 연속, amp 60~120 | lightImpact 반복 |
| `rubTexture` | 사락/뽀드득 | continuous, 속도 비례 | 짧은 펄스 연속 | selectionClick 반복 |
| `shakeBounce` | 벽 튕김 | transient, 강도 비례 | 단발, amp 강도 비례 | mediumImpact |
| `heartbeat` | 두-근 | transient×2(간격 120ms) 주기 800ms 반복 | 패턴 `[0,60,120,60]` 반복 | medium+light 2연타 |
| `shredGrind` | 갈림 | continuous, sharpness↑ | 강한 연속, amp 200 | heavyImpact 반복 |
| `tear` | 찢김 | transient sharp 1회 | 단발 amp 180 | mediumImpact |
| `burst` | 폭죽 | transient 강+여운 | amp 255 단발 후 잔진동 | heavyImpact |
| `knotPop` | 톡 | transient soft | 단발 amp 90 | selectionClick |

`intensity`(0~1)는 연속 패턴에서 실시간 갱신한다(예: 흔들기 강도 → `shakeBounce`/`pressHum` 강도).

## 2. iOS Core Haptics 채널 골격
- 네이티브: `CHHapticEngine` 생성·시작, `CHHapticEvent`(transient/continuous) + `CHHapticDynamicParameter`로 실시간 intensity/sharpness 변조.
- platform channel(MethodChannel `app/haptics`): `play(pattern, intensity)`, `startContinuous(pattern)`, `updateIntensity(v)`, `stop()`.
- 엔진 reset/stopped 핸들러 등록(인터럽션 복구). 미지원(`CHHapticEngine.capabilitiesForHardware().supportsHaptics == false`) 시 폴백 신호.

## 3. Android vibration 골격
- `vibration` 패키지: `Vibration.hasVibrator()`, `hasAmplitudeControl()` 확인.
- 단발: `Vibration.vibrate(duration: ms, amplitude: 1~255)`.
- 패턴: `Vibration.vibrate(pattern: [...], intensities: [...])`(amplitude 지원 시).
- amplitude 미지원: duration 패턴만으로 근사.

## 4. 폴백 전략
- 연속 패턴(`pressHum`/`rubTexture`/`shredGrind`)을 폴백에서 흉내낼 땐 짧은 임팩트를 인터벌 타이머로 반복(과하지 않게).
- 가변 강도를 폴백에서 표현 못하면 강/중/약 3단계로 양자화.

## 5. 역량 감지 (graceful degradation)
```
if (iOS && supportsHaptics) -> IosCoreHaptics
else if (Android && hasAmplitudeControl) -> AndroidAmplitude
else if (hasVibrator) -> AndroidPattern (고정)
else -> FallbackHaptics (HapticFeedback)  // 웹 포함, 무해
```
- 설정에서 햅틱 OFF면 NoopHaptics. 어떤 분기에서도 호출부는 동일 API.
