# 고도화 분담안 (3인) — 감정 해소 앱

> 현재 `main`은 동작하는 MVP(온보딩 → 홈 → 글쓰기 → 의식 선택 → 의식 4종 → 완료)입니다.
> 이 문서는 3명이 **충돌 없이 병렬로 고도화**하기 위한 분담·규칙·작업 목록입니다.
> 분담 축: **화면(세로 슬라이스)별 소유** — `features/` 폴더 경계 = 담당 경계 → git 충돌 최소화.

## 한눈에 보기

| 담당 | 슬라이스 | 소유 폴더/파일 | 브랜치 |
|------|----------|----------------|--------|
| **P1** | 입구 & 감정 오브제 | `features/onboarding/`, `features/home/` | `feat/p1-home` |
| **P2** | 흐름 & 기록(상태·데이터) | `features/writing/`, `features/complete/`, `ritual_select_screen.dart`, `state/session.dart` | `feat/p2-flow` |
| **P3** | 의식 인터랙션(핵심) | `features/ritual/rituals/` 4종, `features/ritual/widgets/` | `feat/p3-rituals` |

---

## 현재 MVP에서 발견한 공통 갭 (고도화 거리)

- **감정 선택이 없음** — 기획상 "감정 종류 선택 → 그 색이 오브제 색"인데, 현재 글쓰기 화면에 감정 선택이 빠져 있고 `Emotion` 모델 자체가 없음. → **P1 + P2 협업**
- **영구화가 전혀 없음** — 온보딩이 매번 뜨고(`app.dart`가 항상 `OnboardingScreen`), 해소 기록·"N번 흘려보냈어요" 통계도 저장 안 됨. `shared_preferences`는 깔려 있으나 미사용. → **P2**
- **사운드 없음** — 햅틱(`core/haptics.dart`)만 있고 ASMR/사운드 레이어 없음. → **P3(선택)**

---

## P1 — 입구 & 감정 오브제

**소유:** `features/onboarding/`, `features/home/` (`home_screen.dart`, `emotion_ball.dart`, `emotion_ball_painter.dart`)

작업:
- [ ] 온보딩 비주얼·카피 고도화, 페이드/전환 다듬기
- [ ] 감정 공 제스처 5종(흔들기/굴리기/누르기/문지르기/꽉쥐기) 손맛 튜닝
- [ ] `emotion_ball_painter` 젤리 윤곽·글로우 고도화
- [ ] **신규: 감정 선택 도입** — 감정 종류 선택 → 공/오브제 색 반영 (감정→색 매핑)
  - `Emotion` 모델·`SessionState` 확장은 **P2와 계약 합의 후** 진행

## P2 — 흐름 & 기록 (상태·데이터 담당)

**소유:** `features/writing/`, `features/complete/`, `features/ritual/ritual_select_screen.dart`, `state/session.dart`

작업:
- [ ] 글쓰기 UX(무한 두루마리 느낌, 입력 압박 제거), 의식 선택 화면 다듬기
- [ ] **신규: 영구화 레이어** — `shared_preferences` 래퍼(`core/` 또는 `services/`)
  - [ ] 온보딩 완료 플래그(두 번째 실행부터 홈 직행, `app.dart` 분기)
  - [ ] 해소 기록(날짜 + 감정 + 의식 종류). **글 내용은 저장하지 않음**(흘려보내기 원칙)
- [ ] **신규: 완료 화면 통계** — "지금까지 N번 흘려보냈어요" 누적 표시
- [ ] `Emotion` 모델 신설 + `SessionState` 확장 (P1과 계약 공유)

## P3 — 의식 인터랙션 (앱의 핵심)

**소유:** `features/ritual/rituals/`(`burn`, `shredder`, `paper_plane`, `jewelry_box`), `features/ritual/widgets/`(`particles.dart`, `paper_card.dart`)

작업:
- [ ] 의식별 애니메이션 고도화: 태우기(불꽃·재), 파쇄기(조각·폭죽), 종이비행기(접기·비행), 보석함(안치)
- [ ] 파티클 시스템(`particles.dart`) 강화
- [ ] 의식별 햅틱 시퀀스 추가 (`core/haptics.dart` 패턴 확장)
- [ ] **신규(선택): 사운드 레이어** — `audioplayers`로 의식별 ASMR

---

## 충돌 방지 규칙 (세로 슬라이스의 핵심)

공유 파일은 **소유자**를 정하고, 나머지는 *요청 → 소유자가 반영*한다.

| 공유 파일 | 소유자 | 비고 |
|-----------|--------|------|
| `state/session.dart` | **P2** | 모델/상태 변경은 P2가 일괄 반영 |
| `theme/app_theme.dart` (색·토큰) | **P1** | 디자인 토큰 단일 출처 |
| `core/haptics.dart` | **P3** | 햅틱 패턴 추가는 P3 |
| `core/strings.dart`, `app.dart`, `main.dart` | 변경 시 **공지 후** | 라우팅·진입점, 합의 필요 |

---

## Git 워크플로

1. 작업 전 **`main` 최신화**: `git checkout main && git pull origin main`
2. **피쳐 브랜치 생성**: `feat/p1-home` / `feat/p2-flow` / `feat/p3-rituals` (작은 단위로 쪼개도 좋음)
3. 작업 → 작은 단위로 **커밋**
4. **push** 후 **main으로 PR** → 리뷰 → 머지
5. 폴더가 갈려 있어 충돌은 거의 없지만, **공유 파일을 건드릴 땐 먼저 팀에 공지**

> 분량: P3(의식 4종 ≈ 900줄 폴리싱)가 가장 무겁고, P2는 기존 코드는 적지만 **영구화·통계·감정 모델 신규 작업**이 많아 균형이 맞습니다.
