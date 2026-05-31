---
name: haptics-sensory
description: 감정 오브제 명상 앱의 핵심 차별점 — 햅틱·센서·사운드 구현 패턴. 햅틱 패턴 엔진(iOS Core Haptics 채널 / Android vibration amplitude / HapticFeedback 폴백), sensors_plus 모션 매핑(흔들기·기울기·던지기), graceful degradation, ASMR 사운드. sensory-haptics 에이전트가 진동·센서·소리를 구현할 때 사용. 햅틱/진동/센서/사운드 작업이면 반드시 이 스킬.
---

# haptics-sensory — 햅틱·센서·사운드 구현

sensory-haptics가 이 제품의 가장 중요한 차별점을 구현하기 위한 패턴. 정본: `docs/PRODUCT_SPEC.md`(2.5, 2.6, 5장).

## 왜 이렇게 하는가
햅틱은 "알림"이 아니라 **촉감의 재현**이다. 단발 임팩트만으로는 "살아있는 오브제"가 되지 않는다 — 강도가 연속으로 변해야(흔들수록 세게, 누를수록 깊게) 촉각 환상이 생긴다. 그리고 사운드 OFF·햅틱 미지원 기기에서도 경험이 무너지지 않도록 **추상 API + graceful degradation**으로 설계한다.

## 아키텍처: 추상 햅틱 API + 플랫폼 분기
화면/모션 코드는 패턴명만 호출하고, 엔진이 플랫폼을 분기한다.
```dart
abstract class Haptics {
  Future<void> play(HapticPattern p, {double intensity = 1.0});
  Future<void> startContinuous(HapticPattern p);  // 가변 강도 갱신 가능
  Future<void> updateIntensity(double v);
  Future<void> stop();
}
// 런타임 역량 감지 → IosCoreHaptics / AndroidAmplitude / FallbackHaptics 선택
```

## 햅틱 패턴 카탈로그 (스펙 5.1)
패턴명으로 호출. 플랫폼별 구현·폴백은 `references/haptic-patterns.md` 참조.
- `tapPop` 통 · `pressHum` 누름지속(연속) · `rubTexture` 사락(속도비례 연속) · `shakeBounce` 벽튕김(강도비례) · `heartbeat` 두-근(주기 반복) · `shredGrind` 갈림(강한 연속) · `tear` 찢김 · `burst` 폭죽 · `knotPop` 톡.

## 플랫폼 구현 요지
- **iOS:** Core Haptics(`CHHapticEngine`)는 Flutter 기본 미지원. platform channel로 네이티브 연속/가변 햅틱(AHAP 또는 이벤트 스트림) 구현, 또는 `flutter_apple_haptics`. **연속·가변이 핵심이므로 iOS는 채널 구현을 우선 검토.**
- **Android:** `vibration` 패키지 — `duration`/`pattern`/`amplitude`(API 26+). amplitude 미지원 기기는 고정 패턴.
- **폴백:** Flutter 내장 `HapticFeedback`(light/medium/heavy/selectionClick). 웹·미지원에서 무해.
- 상세 코드 골격과 폴백 매핑: `references/haptic-patterns.md`.

## 센서 매핑 (스펙 5.3)
builder의 단일 센서 서비스(`sensors_plus`)에서 값을 받아 변환:
- 흔들기 강도 = `userAccelerometer` 벡터 크기 → 진동 amplitude·튕김 속도로 정규화.
- 기울기 = `accelerometer` x·y → 굴리기 가속도 벡터.
- 던지기 = 가속도 피크 급상승 후 급하강 임계 감지.
- 방향감: 벽 방향, "몸쪽으로 굴리면 파도처럼 점점 세게" 같은 뉘앙스를 강도 곡선으로.

## 사운드 (ASMR)
- 작고 가까운 질감음(사락/뽀드득/화르륵/톡), 제스처·의식별 시그니처 1개. `audioplayers`/`just_audio` 원샷·짧은 루프.
- **독립 성립:** 사운드 없이 햅틱만, 햅틱 없이 사운드만으로도 성립. 둘을 강결합하지 않는다.

## 원칙
- **설정 존중:** 햅틱/사운드 ON·OFF·민감도를 발동 전 확인.
- **모션 동기화:** motion-crafter의 비주얼 progress/콜백 시점에 맞춰 트리거.
- **graceful degradation:** 런타임 역량 감지 → 단계적 강등. 어떤 기기에서도 크래시 없이.
- **실기기 한계:** 에뮬레이터/웹은 실제 촉감 검증 불가 → 코드 경로·폴백·크래시 가드를 보장하고, 촉감 튜닝은 notes에 "실기기 필요"로.

## 출력
- `lib/services/` 햅틱·센서·사운드 코드(+ iOS/Android 네이티브 채널 코드) + `_workspace/02_haptics_{기능명}_notes.md`(패턴, 플랫폼 분기, 폴백 경로, 실기기 검증 필요 항목).
