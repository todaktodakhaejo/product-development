---
name: flutter-implementation
description: 감정 오브제 명상 앱의 화면·상태(RitualSession)·라우팅·센서 서비스·에셋/패키지를 Flutter/Dart로 구현하는 컨벤션. 파스텔 claymorphism 테마 토큰, Provider/Riverpod 세션 상태, PageRouteBuilder 전환, sensors_plus 서비스 배선, 폰트/사운드 번들. flutter-builder 에이전트가 screens/state/services 코드를 작성·수정할 때 사용.
---

# flutter-implementation — Flutter 구현 컨벤션

flutter-builder가 화면 골격·세션 상태·라우팅·에셋·센서 배선을 일관되게 구현하기 위한 패턴. 정본: `docs/PRODUCT_SPEC.md`(6장 아키텍처 노트).

## 왜 이렇게 하는가
시각 모션과 햅틱/사운드는 전담 에이전트가 채운다. 빌더가 만드는 것은 그들이 끼워넣을 **안정적인 골격과 인터페이스**다. 골격이 흔들리면 모든 감각 작업이 무너지므로, 빌더는 화려함보다 명확한 슬롯·상태·서비스 경계를 우선한다.

## 컨벤션
- **언어:** 모든 주석·문서주석(`///`)은 한국어. 클래스/메서드 위 한 줄 의도 주석.
- **테마 토큰:** 스펙 2.2 컬러 토큰을 `AppTheme`에 세만틱 상수로 1:1 정의(`bgGradientTop`, `objectBase`, `glow`, `paper`, `textPrimary`, `accentFireHot` 등). 화면에서 직접 HEX 금지.
- **타이포:** Pretendard 등 폰트를 `assets/fonts`에 번들하고 `ThemeData.textTheme`로 위계 정의(타이틀 18~20 / 설명 13~14 / 미세 11~12, 큰 행간).

## 상태: RitualSession
한 세션의 상태를 단일 모델로 들고 다닌다. 화면 간 인자 전달은 이 모델로 통일한다.
```dart
/// 한 번의 의식(Soothe→Pour→Release→Closing) 동안의 세션 상태.
class RitualSession extends ChangeNotifier {
  String memoText = '';
  Emotion? emotion;
  RitualType? ritualType;
  RitualPhase phase = RitualPhase.soothe;
  // ... 단계 전환 메서드. notifyListeners()로 화면 갱신.
}
```
- 상태관리는 프로젝트 채택안(Provider/Riverpod 중 1) 고정. 화면은 세션을 watch/read한다.
- 글 내용(`memoText`) 영구 저장 정책은 명세를 따른다(기본: 의식 후 비움).

## 라우팅
- 단계별 페이지를 커스텀 `PageRouteBuilder`로 페이드/모프 전환(전환 골격만; 세부 모션은 motion-crafter가 채움).
- 기존 `route_transitions.dart`의 `fadeRoute` 패턴을 재활용·확장.

## 센서 서비스 배선 (중요)
- `sensors_plus` 스트림을 구독하는 **단일 서비스**를 만들고, motion-crafter(시각 물리)와 sensory-haptics(진동 강도)가 함께 소비하도록 값/스트림을 노출한다. 화면마다 따로 구독하지 않는다.
- 구독은 `initState`에서, **해제는 반드시 `dispose`에서**(누수·배터리). 미지원 기기·웹에서 스트림이 없으면 빈 스트림으로 가드.

## 에셋·패키지
- `pubspec.yaml`에 명세에 명시된 패키지만 추가: `sensors_plus`, `vibration`, `audioplayers`/`just_audio`, 폰트.
- 사운드는 `assets`에 짧은 원샷/루프로 번들. 경로 상수화.

## 설정
- 햅틱 ON·OFF, 사운드 ON·OFF, 모션 민감도를 설정 모델로. 무음·진동만 모드에서도 전체 경험이 성립해야 한다.

## 안정성 가드
- 컴파일 깨지는 변경 금지. 센서/햅틱/플랫폼 API는 미지원 환경에서 크래시 없이 가드.
- 비동기 후 네비게이션 전 `mounted` 체크.

## 출력
- `lib/` 코드 + `_workspace/02_builder_{기능명}_notes.md`(변경 파일, 정의한 슬롯/스트림 시그니처, 추가 패키지, 미해결 이슈).
