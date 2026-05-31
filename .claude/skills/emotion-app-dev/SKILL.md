---
name: emotion-app-dev
description: 감정 오브제 명상 앱(Soothe→Pour→Release→Closing)의 기능을 에이전트 팀으로 구현·확장하는 오케스트레이터. 새 화면/제스처/의식/햅틱 구현, 기존 기능 수정·보완·재실행, "이 의식 추가해줘/오브제 동작 바꿔줘/햅틱 다시/이전 결과 개선" 등 앱 기능 개발 요청 시 사용. 단순 질문은 직접 응답 가능.
---

# emotion-app-dev — 감정 오브제 명상 앱 개발 오케스트레이터

감정 오브제 명상 앱의 기능 구현을 6인 에이전트 팀으로 조율한다. 정본 기획: `docs/PRODUCT_SPEC.md`.

**실행 모드:** 에이전트 팀(기본) · 하이브리드 파이프라인 + 생성-검증
**팀(6명):** `product-planner` → (`flutter-builder` ‖ `motion-crafter` ‖ `sensory-haptics`) → `design-guardian` + `qa-integrator`
**모델:** 모든 에이전트 호출에 `model: "opus"`.

## Phase 0: 컨텍스트 확인 (먼저)
1. `_workspace/` 존재 여부와 사용자 요청을 보고 실행 모드 결정:
   - 미존재 → **초기 실행**(전체 파이프라인).
   - 존재 + 부분 수정 요청("이 의식만/햅틱만 다시") → **부분 재실행**(해당 에이전트만 재호출, 기존 산출물 입력).
   - 존재 + 새 기능 입력 → **새 실행**(기존 `_workspace/`를 `_workspace_prev/`로 이동 후 시작).
2. `docs/PRODUCT_SPEC.md`와 기존 `lib/` 현황을 확인(프로토타입 ↔ 정본 갭 인지).

## Phase 1: 기획 → 명세
- **실행:** `product-planner` 단독(서브 또는 팀 리더 작업).
- 요청을 `_workspace/01_planner_{기능명}_spec.md`로. 감각 3종 세트·센서 매핑·기기 폴백·수용 기준 포함. MVP 단계(필수①②③④/2차⑤⑥/확장⑦⑧⑨) 반영.
- 명세가 모호하면 사용자에게 질문 후 진행.

## Phase 2: 병렬 구현 (에이전트 팀)
- **실행:** `TeamCreate`로 팀 구성, `TaskCreate`로 작업 할당. `flutter-builder`·`motion-crafter`·`sensory-haptics`가 병렬 구현하며 `SendMessage`로 인터페이스를 자체 조율.
- **분담:**
  - builder: 화면 골격·`RitualSession`·라우팅·센서 서비스 배선·에셋/패키지(슬롯·스트림 노출).
  - motion-crafter: blob·파티클·연소/파쇄/찢기·morph 전환(builder 슬롯에 결합).
  - sensory-haptics: 햅틱 엔진·센서 매핑·사운드(builder 스트림·motion 타이밍에 동기화).
- **핵심 조율점:** ①builder가 센서 서비스/위젯 슬롯 시그니처를 먼저 확정해 모션·햅틱에 공유 ②motion↔haptics가 비주얼 progress/콜백 시점 동기화 ③같은 파일은 편집 구간 분담.

## Phase 3: 검증 (생성-검증)
- **실행:** `design-guardian`(톤·토큰·카피)과 `qa-integrator`(경계면·degradation·analyze/test)가 검수. qa는 general-purpose로 실제 스크립트 실행.
- **점진적 QA:** 각 모듈 완성 직후 검증을 권장(전체 후 1회 금지).
- 발견 이슈는 책임 에이전트에 `SendMessage`로 돌려 1회 수정 → 재검증.

## Phase 4: 종합 & 정리
- 리더가 `_workspace/` 산출물을 종합해 사용자에게 변경 요약(변경 파일·구현 감각·실기기 필요 항목·미해결) 보고.
- 팀 정리(`TeamDelete`). 최종 코드는 `lib/`에, 중간 산출물은 `_workspace/` 보존.

## 데이터 전달 프로토콜
- **태스크 기반**(`TaskCreate`/`Update`): 조율·의존·진행 추적.
- **메시지 기반**(`SendMessage`): 인터페이스 합의·실시간 피드백.
- **파일 기반**: `_workspace/{phase}_{agent}_{artifact}.md` 중간 산출물, `lib/` 최종 코드.
  - 명명: `01_planner_*_spec.md`, `02_builder_*_notes.md`, `02_motion_*_notes.md`, `02_haptics_*_notes.md`, `03_design_*_review.md`, `04_qa_*_report.md`.

## 에러 핸들링
- 에이전트 1회 재시도 후 재실패 → 해당 산출물 없이 진행하되 최종 보고에 누락 명시.
- 상충 데이터(예: QA 통과 vs 디자인 위반)는 삭제하지 말고 출처 병기.
- 컴파일 깨짐 → qa-integrator가 `flutter analyze`로 확인, 책임 에이전트에 반려.
- 실기기 전용 검증 불가 항목 → "실기기 필요"로 명시(차단하지 않음).

## 팀 크기
- 6명(중~대규모). 한 기능이 작으면 관련 에이전트만 부분 호출(예: 햅틱 튜닝만 → planner 갱신 + sensory-haptics + qa).

## 테스트 시나리오
- **정상 흐름:** "모닥불 의식 추가" → planner 명세(연소 비주얼+화르륵 사운드+`shredGrind`/연속 햅틱+아래→위 방향감+폴백) → builder(ReleaseRitualPage 분기·세션) ‖ motion(연소 애니) ‖ haptics(연속 진동·사운드) → design(불꽃 강조색·카피 "재가 되어 사라져요") + qa(세션 인자·dispose·폴백·analyze) → 종합 보고.
- **에러 흐름:** sensory-haptics가 iOS 채널 구현 실패 → 1회 재시도 후 폴백(HapticFeedback) 경로만 구현, notes·최종 보고에 "Core Haptics 실기기/네이티브 작업 필요" 명시하고 나머지 파이프라인은 계속 진행.

## Phase 5: 피드백 (실행 후)
- "결과에서 바꾸고 싶은 점이 있나요?" 1회 질문. 피드백은 유형별 반영:
  결과 품질→해당 스킬 / 역할→에이전트 정의 / 순서→이 오케스트레이터 / 트리거 누락→description / 톤→design-tone-guard.
- 변경은 `CLAUDE.md`의 하네스 변경 이력에 기록.
