# 제품 분석 명세 (PostHog)

> 사용자 행동·통계를 보기 위한 분석 계측 명세서입니다.
> **서버를 직접 만들지 않습니다.** 앱에 PostHog SDK를 붙여 이벤트를 보내면,
> PostHog가 인입·저장·대시보드(리텐션/퍼널/세그먼트)를 전부 제공합니다.
> 이 문서는 **팀 공통 기준**이며, 각자 자기 Claude에게 이 문서를 근거로 작업을 시킵니다.

---

## 0. 원칙 — 프라이버시 (최우선, 절대 규칙)

이 앱의 정체성은 **"기록하지 않고 흘려보내기"** 입니다. 분석도 이 약속을 지킵니다.

1. **감정 글의 '내용'은 절대 전송 금지.** 오직 **글자 수(length)** 만 보냅니다.
2. **익명 UUID만** 사용합니다. 이름·이메일·전화 등 **개인정보(PII) 전송 금지.**
   - UUID는 앱 첫 실행 때 한 번 생성해 `StorageService`(기기 로컬)에 저장·재사용.
3. **옵트아웃 제공** — 설정에 **"사용 데이터 수집 끄기"** 토글. 끄면 그 순간부터 이벤트 전송 중단.
   - 기본값: 수집 ON. (글 내용을 안 보내므로 옵트아웃 방식으로 충분하다고 판단)
4. 위 원칙을 어기는 속성/이벤트는 추가하지 않는다. (리뷰 시 필수 확인 항목)

---

## 1. 도구 / 계정

- **도구:** PostHog (무료 플랜: 월 100만 이벤트 — 예상 볼륨 한참 안쪽)
- **계정:** 공용/대표 이메일로 **1개 생성** → 팀원 **초대**(Settings → Organization → Members).
  - 비밀번호 공유 X. 각자 자기 계정으로 같은 프로젝트 접속.
- **연결에 필요한 값** (소유 계정 → Settings → Project):
  - `Project API Key` (**`phc_`로 시작**, 앱에 넣어도 안전한 공개 키)
  - `Host` (가입 지역: US=`https://us.i.posthog.com` / EU=`https://eu.i.posthog.com`)
  - ⚠️ `Personal API Key`(비밀 키)는 **사용 금지**.

---

## 2. 이벤트 택소노미 (보내는 신호 목록)

> 대부분의 지표(DAU/MAU·리텐션·퍼널·체류시간)는 아래 이벤트로부터 **PostHog가 자동 계산**합니다.
> 사용자 식별: 모든 이벤트는 **익명 UUID(distinct_id)** 와 함께 전송.

| 이벤트 | 언제 | 속성(같이 보내는 값) | 담당 |
|--------|------|----------------------|------|
| `app_opened` | 앱 실행 시 | — | 토대(P2) |
| `session_started` | 세션 시작 시 | — | 토대(P2) |
| `home_viewed` | 홈(오브제) 화면 표시 | — | P1 |
| `gesture_performed` | 제스처 발생 시 | `gesture_type`(shake/roll/press/rub), `duration_ms` | P1 |
| `writing_started` | 글쓰기 화면 진입 | — | P2 |
| `writing_completed` | '이 마음 보내기' 눌러 진행 | `char_count` *(내용 제외, 글자 수만)* | P2 |
| `ritual_selected` | 의식 카드 선택 | `ritual_type`(burn/shredder/paperPlane/jewelryBox) | P2 |
| `ritual_completed` | 의식 끝까지 완료 | `ritual_type` | P3 |
| `completion_viewed` | 완료 화면 표시 | — | P2 |
| `session_summary` *(2차)* | 세션 종료 시 1건 | `first_action`(gesture/writing), `is_text_written`, `char_count`, `total_gesture_ms`, `ritual_type`(or null), `time_bucket`(일출/낮/노을/밤/새벽), `duration_ms` | P2 |

> `session_summary`는 persona·시간대·진입순서 분석을 한 번에 보기 위한 **편의 이벤트**(2차).
> 없어도 위 개별 이벤트만으로 대부분 지표가 나옵니다 → **1차엔 생략 가능**, 여유 될 때 추가.

---

## 3. 지표 → 이벤트 매핑

| 지표 | 어떻게 나오나 | 우선순위 |
|------|---------------|----------|
| DAU / MAU | `app_opened` + 익명 UUID → PostHog 자동 | 필수 |
| 재방문율(Retention) | `app_opened`/`session_started` → PostHog 리텐션 | 필수 |
| 평균 체류 시간 | `session_summary.duration_ms` (또는 PostHog 세션) | 필수 |
| 총 해소 성공률 | 퍼널: 방문 → (`writing_completed` 또는 제스처 교감) ※성공 정의는 §5 미결정 | 필수 |
| 인당 평균 의식 횟수 | `ritual_completed` 수 ÷ 고유 유저 | 필수 |
| 단계별 퍼널 전환율 | `home_viewed`→`gesture_performed`→`writing_started`→`ritual_selected`→`ritual_completed`→`completion_viewed` | 필수 |
| 글쓰기→의식 이탈률 | 퍼널 `writing_started`→`ritual_completed` 이탈 | 필수 |
| 의식 종류별 점유율 | `ritual_completed.ritual_type` 분해 | 권장 |
| 제스처별 인터랙션 밀도 | `gesture_performed.gesture_type` + `duration_ms` | 권장 |
| 유저 성향(persona) | `session_summary`(is_text_written, total_gesture_ms)로 군집 | 권장 |
| 글쓰기 분량 분포 | `writing_completed.char_count` *(내용 X)* | 권장 |
| 사용 시간대 분포 | `session_summary.time_bucket` | 권장 |
| 진입 행동 순서 | `session_summary.first_action` | 권장 |

> ❌ 제외: **임계점 도달률(폰 꽉 쥐기, GST-05)** — 해당 제스처가 구현 불가로 제외됨.

---

## 4. 작업 분배 & 순서 (비개발자용 — 각자 Claude에게 시킴)

**먼저 준비물(1회):** 위 §1의 PostHog 가입 + `phc_` 키/호스트 확보 → 토대 담당(P2)에게 전달.

| 순서 | 담당 | 할 일 |
|------|------|-------|
| **0** | **P2** | **공통 토대** — SDK 설치, `AnalyticsService` 래퍼, 익명 UUID, 옵트아웃, `app_opened`/`session_started`. **먼저 완성·머지** |
| 1 | P1 | `home_viewed`, `gesture_performed` (홈 화면) |
| 2 | P2 | `writing_started`/`writing_completed`/`ritual_selected`/`completion_viewed` (+ `session_summary` 2차) |
| 3 | P3 | `ritual_completed` (의식 화면) |

> ⚠️ **0번(토대)을 main에 합친 뒤** 1~3을 시작. (그래야 부를 함수가 존재함)
> 타이밍: 기능 배치 머지로 **코드가 안정된 뒤** 계측 삽입 권장(바뀌는 코드에 또 손대는 것 방지).

### 각자 Claude에게 줄 프롬프트

**① P2 — 토대**
```
PostHog 분석을 우리 Flutter 앱에 붙이려고 해. docs/ANALYTICS.md 명세를 따라줘.
1) posthog_flutter 패키지 추가
2) core/analytics.dart 에 AnalyticsService 래퍼: PostHog 초기화 + 명세의 이벤트를
   보내는 의미 있는 메서드들 정의(예: ritualCompleted(type))
3) 사용자 식별은 익명 UUID로만 (StorageService에 저장·재사용). 개인정보 금지
4) 감정 글 '내용' 전송 금지 — 글자 수만
5) 앱 시작 시 app_opened/session_started, 설정에 '사용 데이터 수집 끄기'(옵트아웃)
6) PostHog 키/호스트는 내가 줄게: [phc_... / https://...posthog.com]
끝나면 main 최신화 → 브랜치 → 커밋 → PR까지. push 전 확인받고.
```

**② P1 — 제스처**
```
docs/ANALYTICS.md 대로, 내 담당 홈 화면(features/home/)에 분석 이벤트를 넣어줘.
- 화면 표시 시 home_viewed
- 제스처(흔들기/굴리기/누르기/문지르기) 발생 시 gesture_performed
  (속성: gesture_type, duration_ms)
- AnalyticsService(core/analytics.dart, P2가 만듦)의 메서드를 호출만 해. 개인정보·글 내용 금지
끝나면 main 최신화 → 브랜치 → 커밋 → PR까지. push 전 확인받고.
```

**③ P3 — 의식 완료**
```
docs/ANALYTICS.md 대로, 내 담당 의식 화면(features/ritual/rituals/)에서
의식을 끝까지 완료하면 ritual_completed(속성: ritual_type)를
AnalyticsService(core/analytics.dart, P2가 만듦)로 보내줘. 호출만 하면 돼.
개인정보·글 내용 전송 금지.
끝나면 main 최신화 → 브랜치 → 커밋 → PR까지. push 전 확인받고.
```

---

## 5. 미결정 (팀 논의 필요)

- **옵트아웃 위치:** 현재 앱에 설정 화면이 없음. "수집 끄기" 토글을 어디에 둘지(설정 화면 신설 / 온보딩 / 홈 모서리). → 토대 작업 시 최소 설정 화면 같이 신설 검토.
- **"해소 성공" 정의:** 총 해소 성공률의 분자(글쓰기 완료 + "촉각 교감 성공")에서 *촉각 교감 성공*의 기준(제스처 횟수/시간 임계치)을 수치로 확정.
- **동의 고지:** 옵트아웃만으로 충분한지, 첫 실행 시 한 줄 고지("익명 사용 통계를 수집해요")를 둘지.
