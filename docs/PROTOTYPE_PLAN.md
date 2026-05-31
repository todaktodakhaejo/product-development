# 감정 해소 앱 — 핵심 플로우 프로토타입 설계

> 출처: 기획서(2026.05.27 회의 / 05.29 정리). 한 줄 정의 — "감정을 '기록'하는 것이 아니라 '흘려보내며 해소'하는 앱".

## 목표 (이번 프로토타입 범위)
온보딩 → 홈 → 제스처 → 감정 글쓰기 → 의식(분출) → 완료 까지의 **핵심 경험**을 실제로 동작하게.
- 플랫폼: Flutter (iOS/Android 크로스플랫폼). 1차 확인은 Chrome(웹), 추후 Android 에뮬레이터/팀 Mac으로 iOS.
- 저장: 기기 내 로컬(`shared_preferences`). **감정 내용은 저장하지 않음** — "흘려보내기"가 핵심이므로 글 내용은 의식과 함께 사라지고, 해소 기록(날짜·감정 종류·횟수)만 남긴다.

## 화면

### 1. 온보딩 (OnboardingScreen)
- 2~3페이지. "기록하지 말고, 흘려보내세요" 컨셉 전달.
- 차분한 그라데이션 배경, 부드러운 페이드. 마지막에 "시작하기".
- 완료 플래그 로컬 저장 → 다음 실행부터는 홈으로 직행.

### 2. 홈 (HomeScreen)
- 정적이고 고요한 화면. 중앙에 천천히 호흡(scale)하는 오브(BreathingOrb).
- 카피: "지금 마음에 머무는 감정이 있나요?"
- 제스처 인터랙션: 오브를 **꾹 누르거나 위로 쓸어올리면** 글쓰기로 전환.

### 3. 감정 글쓰기 (WriteScreen)
- 먼저 감정 종류 선택(EmotionPicker) → 선택한 감정의 색이 오브제 색이 됨.
- 자유 글쓰기. 글자 수 제한 없음, 압박 없는 UI.
- 입력한 텍스트가 다음 단계에서 시각적 오브제로 변환됨.

### 4. 의식 / 분출 (RitualScreen) — 경험의 핵심
- 작성한 텍스트가 화면에 떠오른 뒤, **위로 쓸어올리는 제스처**로 글자가 입자(particle)로 흩어져 사라짐.
- `CustomPainter` 기반 파티클 분산 애니메이션 + 감정 색의 잔광.
- 햅틱 피드백(모바일). 끝나면 화면이 비워지며 정적.

### 5. 완료 (CompletionScreen)
- "흘려보냈어요" 잔잔한 메시지 + 부드러운 잔광.
- 로컬에 해소 기록 1건 추가(날짜 + 감정 종류). 내용은 저장 안 함.
- "지금까지 N번 흘려보냈어요" 가벼운 누적 표시. 홈으로 복귀.

## 감정 → 색 매핑 (오브제화)
| 감정 | 색 계열 |
|------|---------|
| 분노 | 따뜻한 적/주황 |
| 불안 | 보라 |
| 슬픔 | 청색 |
| 공허 | 회색 |
| 후회 | 청록 |
| 분함 | 자홍 |

## 기술 구성
```
lib/
  main.dart
  app.dart                  # MaterialApp + 라우팅 + 온보딩 분기
  theme/app_theme.dart      # 색/그라데이션/타이포
  models/emotion.dart       # 감정 enum + 라벨/색
  models/release_record.dart
  services/storage_service.dart  # shared_preferences 래퍼
  screens/onboarding_screen.dart
  screens/home_screen.dart
  screens/write_screen.dart
  screens/ritual_screen.dart
  screens/completion_screen.dart
  widgets/breathing_orb.dart
  widgets/particle_field.dart    # 파티클 분산 CustomPainter
  widgets/emotion_picker.dart
```
- 상태관리: 프로토타입 단계라 `Navigator` + `setState`로 단순하게.
- 의존성 최소화: `shared_preferences`만 추가(폰트/애니 패키지는 손으로 구현해 오프라인·웹 안정성 확보).

## 디자인 톤
- 어둡고 고요한 배경(딥 인디고/차콜 그라데이션) + 부드러운 글로우.
- 여백 큰 타이포, 한국어, 큰 자간·행간. 압박 없는 무드.
