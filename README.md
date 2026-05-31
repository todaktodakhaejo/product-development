# 감정 해소 앱 (Emotion Resolution App)

> 감정을 '기록'하는 것이 아니라 **'흘려보내며 해소'** 하는 앱.
> 감정을 **오브제화**하여 직면하고, **의식(분출 행위)** 으로 시각적으로 흘려보낸다.

Flutter로 구현한 MVP. 기능명세서의 **우선순위 '필수'** 기능을 우선 구현했습니다.

---

## 실행 방법

> ⚠️ 이 저장소에는 `lib/`, `pubspec.yaml` 등 **소스만** 들어 있습니다.
> iOS/Android 네이티브 폴더는 `flutter create`로 생성해야 합니다.

```bash
# 0) Flutter SDK 설치 (3.27+ / Dart 3.6+ 필요: Color.withValues 사용)
flutter --version

# 1) 네이티브 플랫폼 폴더 생성 (pubspec.yaml / lib/main.dart 를 덮어씀)
flutter create . --project-name emotion_resolution_app --org com.emotion --platforms=android,ios

# 2) 덮어쓰인 내 소스 복구 (이 저장소가 git 관리 중일 때)
git checkout -- pubspec.yaml lib/main.dart

# 3) 의존성 설치 후 실행 (실기기 권장: 햅틱·센서)
flutter pub get
flutter run
```

> 햅틱과 가속도 센서는 **실제 기기**에서만 제대로 동작합니다. 시뮬레이터는 진동/센서가 제한적입니다.

---

## 폴더 구조

```
lib/
  main.dart, app.dart            # 진입점 / MaterialApp·세션 주입
  theme/app_theme.dart           # 색·그라데이션·배경
  core/
    haptics.dart                 # ⭐ 햅틱 엔진 (세기 매핑 + 타임라인 큐)
    strings.dart                 # 위로/완료 멘트
  state/session.dart             # 세션 상태(글·의식) + Ritual 정의
  features/
    onboarding/                  # ONB-01
    home/                        # ⭐ 공 오브제 물리 + 5개 제스처
      emotion_ball.dart          #   물리/변형 모델
      emotion_ball_painter.dart  #   렌더링
      home_screen.dart           #   센서·포인터·루프 통합
    writing/                     # WRT-01/02
    ritual/                      # RIT 의식 선택 + 4종
      widgets/                   #   PaperCard, 파티클 시스템
      rituals/                   #   태우기·파쇄기·종이비행기·보석함
    complete/                    # END-01/03/04
```

---

## 필수 기능 ↔ 구현 매핑

| 기능 ID | 기능 | 구현 위치 / 방식 |
|---|---|---|
| ONB-01 | 온보딩 | `onboarding_screen.dart` — '기록이 아닌 해소' 3페이지 |
| HOME-03 | 위로 멘트 | `home_screen.dart` — 진입 노출, 첫 터치 시 페이드아웃 |
| HOME-04 | 공 오브제 터치 | 공 물리 오브제(`emotion_ball.dart`), 터치가 매개 |
| HOME-05 | 화면 전환 | 공을 **꾹 쥐면**(GST-05) 종이 등장 → 글쓰기 (+대체 버튼) |
| GST-01 | 흔들기 | `userAccelerometerEventStream` 임펄스, 세기별 햅틱, 벽 충돌 진동 |
| GST-02 | 굴리기 | `accelerometerEventStream` 기울기 중력, 시작/충돌 진동 |
| GST-03 | 누르기 | 탭 → 물결(Ripple) + 뗄 때 `selectionClick` |
| GST-04 | 잡고 문지르기 | 드래그 추종 + 젤리 출렁임 + 지속 약진동 |
| GST-05 | 폰 꽉 쥐기 | 공 위 정지 유지 → 진동 점증 → 임계 돌파 시 팡 |
| WRT-01 | 감정 글쓰기 | `writing_screen.dart` — 비공개 자유 입력 |
| WRT-02 | 글쓰기 진입 | 홈 전환(꾹 쥐기) / 바로 글쓰기 버튼 |
| RIT-01 | 태우기 | 드래그로 불 끌어올림, 아래→위 햅틱, 불씨 파티클, 촛불 마무리 |
| RIT-04 | 파쇄기 | 종이 투입(진동) → 종잇조각 폭죽 분출 |
| RIT-09 | 종이비행기 | 탭 접기(단계별 햅틱) → 던지기(velocity)로 비행 |
| RIT-10 | 보석함 보관 | 종이 투입 → 뚜껑 닫힘 → 후광 (간직형) |
| END-01 | 의식별 마무리 | 각 의식 완료 시 고유 잔상(촛불/폭죽/비행기/후광) |
| END-03 | 완료 멘트 | '다 보냈어요' |
| END-04 | 홈 리셋 | 세션 초기화 후 첫 화면 복귀 |

> 미구현(2차 스펙/권장): HOME-01/02/06, RIT-02/03/05/06/07/08. 구조상 쉽게 확장 가능.

---

## 핵심 설계 포인트

### 햅틱 ↔ 모션 동기화 (`core/haptics.dart`)
의식 연출은 단발 진동이 아니라 **애니메이션 진행도(0~1)의 키프레임에 햅틱 큐를 부착**합니다.
```dart
Haptics.instance.playTimeline(controller, const [
  HapticCue(0.3, HapticLevel.light),
  HapticCue(0.6, HapticLevel.medium),
  HapticCue(0.98, HapticLevel.success),
]);
```
드래그로 진행도를 직접 제어하면(태우기·파쇄기) **손동작 속도 → 모션 → 진동**이 한 축에서 움직입니다.

### 제스처 충돌 회피 (`home_screen.dart`)
누르기/문지르기/꽉쥐기를 `GestureDetector` 여러 개로 두면 gesture arena가 충돌하므로,
**`Listener`(raw pointer) 하나**로 받아 이동 거리·정지 시간으로 분기합니다.

### 햅틱 한계와 다음 단계
현재는 Flutter 내장 `HapticFeedback`(고정 단계)만 사용합니다. 질감 있는 파형(태우기 지글거림 등)은
- iOS: **Core Haptics**(AHAP) — `core/haptics.dart`의 `fire()`만 교체하면 됨
- Android: `vibration` 패키지 amplitude 패턴
로 확장하세요.
```

---

## 알려진 한계 / TODO
- 센서 부호(굴리기 방향)는 기기/OS에 따라 튜닝 필요 (`home_screen.dart` 주석 참고).
- `flutter analyze`로 정적 점검 후 실기기 테스트 권장 (작성 환경에 Flutter 미설치로 컴파일 미검증).
- 종이 디졸브/태우기 질감은 향후 `FragmentShader` 또는 Rive로 고도화 가능.
