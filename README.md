# 감정 오브제 명상 앱 (emotion_relief)

> 살아있는 디지털 감정 오브제를 만지며 진정시키고(**Soothe**) → 떠오르는 생각을 종이에 쏟아낸 뒤(**Pour**) → 나만의 의식으로 감정을 해소한다(**Release**) → 다시 나에게 돌아온다(**Closing**).

📄 **전체 기획·디자인 명세는 [`docs/PRODUCT_SPEC.md`](docs/PRODUCT_SPEC.md)** 를 읽어주세요. (톤앤매너, 컬러 토큰, 햅틱 패턴, 화면별 상세)

이 저장소는 **팀 협업용 골격(skeleton)** 입니다. 외부 패키지 없이도 바로 컴파일·실행되며, 세부 인터랙션은 `TODO` 지점에서 각자 채웁니다.

---

## 실행 방법

Windows(PowerShell)에서는 매 셸마다 Flutter/Git PATH를 먼저 잡아야 합니다:

```powershell
$env:Path = "C:\Program Files\Git\cmd;C:\src\flutter\bin;" + $env:Path
flutter pub get
flutter run -d chrome     # 웹에서 빠르게 확인 (Chrome/Edge/Windows 데스크톱 가능)
```

> 햅틱·센서는 **실기기**에서만 실제로 동작합니다. 웹/에뮬레이터에서는 폴백(무해)으로 흐릅니다.

검증:
```powershell
flutter analyze
flutter test
```

---

## 프로젝트 구조

```
lib/
  main.dart / app.dart            # 진입점 · 세션/서비스 주입 · 진정 화면으로 시작
  theme/
    app_colors.dart               # 디자인 컬러 토큰 (SPEC 2.2) — HEX 직접 사용 금지
    app_theme.dart                # 타이포·테마
  models/
    ritual_phase.dart             # 단계 enum (soothe/pour/releaseSelect/...)
    ritual_type.dart              # 의식 종류 enum (파쇄/구김/모닥불/찢기/...) + MVP 구분
    ritual_session.dart           # 세션 상태 (ChangeNotifier) — 화면 간 데이터는 이걸로 통일
  state/
    ritual_scope.dart             # RitualSession을 트리에 노출 (InheritedNotifier)
    app_services.dart             # 햅틱·사운드·센서·설정 묶음 + Scope
  routing/
    route_transitions.dart        # 페이드/모프 전환
  screens/
    soothe_page.dart              # 진정 (오브제 교감)
    pour_page.dart                # 분출 (글쓰기 + 3초 정지 시 의식 시트)
    release_ritual_page.dart      # 해소 (선택된 의식 수행)
    closing_page.dart             # 마무리
  widgets/
    app_background.dart           # 파스텔 그라데이션 + 글로우
    blob_object.dart              # 젤리 오브제 (idle breathing) — CustomPainter
    ritual_sheet.dart             # 의식 선택 시트 (카드 그리드)
    particle_field.dart           # 재사용 파티클 유틸 (의식 효과용)
    rituals/                      # 의식별 인터랙션 위젯 (현재 placeholder)
      ritual_stage.dart           #   공통 골격 (안내 + 완료 버튼)
      shredder/crumple/bonfire/tear_ritual.dart   # MVP 4종
      placeholder_ritual.dart     #   2차/확장 의식 임시 화면
      ritual_interactions.dart    #   RitualType → 위젯 분기
  services/
    haptics/                      # Haptics 추상 API + FallbackHaptics + Factory
    sensors/                      # SensorService 추상 + Noop 폴백
    audio/                        # SoundService 추상 + Noop 폴백
    settings/                     # 햅틱/사운드 ON·OFF · 모션 민감도
```

---

## 팀원이 채울 곳 (`TODO`)

코드에 `// TODO(역할):` 주석으로 확장점을 표시해 두었습니다. 역할별 진입점:

| 역할 | 주로 보는 곳 | 할 일 |
|------|-------------|------|
| **모션/비주얼** | `widgets/blob_object.dart`, `widgets/rituals/*`, `app_background.dart` | blob 베지어 변형·제스처, 의식별 애니메이션(연소/파쇄/찢기), morph 전환 |
| **햅틱/센서/사운드** | `services/haptics/*`, `services/sensors/*`, `services/audio/*` | iOS Core Haptics 채널 / Android amplitude 구현, `sensors_plus` 연결, ASMR 사운드 |
| **화면/상태** | `screens/*`, `state/*`, `models/*` | 화면 로직 보강, 설정 영구화, 라우팅 |

새 의식을 추가하려면: ① `RitualType`에 항목 추가 → ② `widgets/rituals/`에 전용 위젯 → ③ `ritual_interactions.dart` 분기에 등록.

확장용 패키지(`sensors_plus`, `vibration`, `audioplayers` 등)는 `pubspec.yaml`에 주석으로 안내되어 있습니다.

---

## 개발 하네스 (선택)

`.claude/`에 기능 개발용 에이전트 하네스가 구성되어 있습니다(기획→구현→디자인·QA 검증). Claude Code에서 *"모닥불 의식 구현해줘"* 처럼 요청하면 `emotion-app-dev` 오케스트레이터가 작동합니다. 자세한 내용은 `CLAUDE.md` 참조.
