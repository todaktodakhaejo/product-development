---
name: flutter-qa
description: 감정 오브제 명상 앱의 경계면 정합성 검증 + flutter analyze/test 실행 방법. RitualSession 화면 간 전달, 센서 스트림 구독/해제, 햅틱 폴백 경로, 네비게이션 인자의 cross-boundary 비교와 graceful degradation 점검. qa-integrator 에이전트가 각 모듈 구현 직후 검증할 때 사용.
---

# flutter-qa — QA 검증 & 실행

qa-integrator가 경계면 버그를 잡고 정적 분석·테스트를 돌리기 위한 방법. 정본: `docs/PRODUCT_SPEC.md`.

## 왜 경계면인가
이 앱의 버그 대부분은 단일 파일이 아니라 **연결 지점**에서 난다 — A 화면이 `RitualSession`에 안 채운 필드를 B 화면이 읽거나, 센서 스트림을 구독만 하고 `dispose`에서 해제 안 하거나, 햅틱 호출이 엔진 API 시그니처와 어긋나거나. 그래서 "존재 확인"이 아니라 두 쪽 코드를 동시에 읽고 shape을 비교한다.

## 경계면 체크리스트
- **RitualSession 왕복:** 각 필드(memoText/emotion/ritualType/phase)를 **세팅하는 곳**과 **읽는 곳**을 짝지어 확인. 한쪽만 있으면 버그.
- **네비게이션 인자:** `Navigator.push`로 넘기는 인자 ↔ 대상 페이지 생성자/세션 의존.
- **센서 구독/해제:** `sensors_plus` 구독이 `dispose`에서 cancel 되는가(누수·배터리).
- **햅틱 추상 API:** 호출부 패턴명·시그니처 ↔ 엔진 구현·폴백 분기. 미구현 패턴 호출 없는가.
- **graceful degradation:** 웹/에뮬레이터/구형(센서·햅틱·사운드 미지원) 경로에서 크래시 없이 폴백되는가(코드 경로로 확인).
- **제품 철학 회귀:** 자동 강요(강제 전환) 없는가, 글 내용 저장 정책 준수하는가.

## 정적 분석 & 테스트 실행
Windows 셸은 PATH에 Flutter/Git이 없다. 번들 스크립트가 PATH를 세팅하고 `flutter analyze` + `flutter test`를 실행한다:
```
powershell -File .claude/skills/flutter-qa/scripts/check.ps1
```
또는 직접:
```powershell
$env:Path = "C:\Program Files\Git\cmd;C:\src\flutter\bin;" + $env:Path
flutter analyze
flutter test
```
- 실기기 전용(실제 촉감·센서 반응)은 여기서 검증 불가 → report에 "실기기 필요"로 명시.
- 웹 동작 확인이 필요하면 `flutter run -d chrome`(대화형이므로 사용자에게 `!` 실행 제안).

## 점진적 QA
전체 완성 후 1회가 아니라 **각 모듈 완성 직후** 검증한다. 새 화면/의식이 들어올 때마다 그 경계면만 추가로 본다.

## 출력
`_workspace/04_qa_{기능명}_report.md`:
- 수용 기준 체크 결과(명세 항목별 ✅/❌)
- 경계면 버그 목록(심각도·`file:line`·재현·제안 수정)
- graceful degradation 점검 결과
- `flutter analyze`/`test` 출력 요약
- "실기기 필요" 항목 / 미실행·미검증 항목(숨기지 말 것)

버그 발견 시 책임 에이전트(builder/motion/haptics)에 `SendMessage`로 전달하고 수정 후 재검증한다.
