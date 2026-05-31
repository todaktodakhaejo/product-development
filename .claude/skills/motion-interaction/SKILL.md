---
name: motion-interaction
description: 감정 오브제 명상 앱의 시각 모션 구현 패턴 — blob 오브제(베지어+claymorphism), idle breathing, 파티클/불꽃/종이 연소·파쇄·찢기·구김 효과, morph 화면 전환, 스프링 물리. CustomPainter·AnimationController로 부드러운 dreamy 모션을 만들 때 사용. motion-crafter 에이전트가 시각적 움직임·렌더링을 구현할 때.
---

# motion-interaction — 시각 모션 구현 패턴

motion-crafter가 "살아있는 오브제"와 "물리적 해소 의식"의 시각 감각을 구현하기 위한 패턴. 정본: `docs/PRODUCT_SPEC.md`(2.4 모션 원칙, 4장 연출, 6장 렌더링).

## 왜 이렇게 하는가
이 앱의 모션은 "정보 전달"이 아니라 "정서 유발"이다. 빠르거나 딱딱한 모션은 무드를 깨뜨린다. 그래서 모든 곡선·지속시간은 느리고 부드러운 쪽으로 기울이고, 화면은 절대 완전히 멈추지 않는다(idle breathing).

## 핵심 패턴

### 1. blob 오브제 (claymorphism)
- 닫힌 베지어 경로의 제어점 N개(예 6~8개)를 극좌표로 배치하고, 각 반지름을 `AnimationController`+사인파로 미세 변조 → 젤리처럼 출렁이는 윤곽.
- 입체감: `RadialGradient`(highlight→base→core 3톤) + `MaskFilter.blur` soft shadow. 음영 중심을 살짝 위로 치우쳐 빛이 위에서 오는 느낌.
- idle breathing: 0.5~1Hz로 전체 scale ±몇 % 호흡. `repeat(reverse: true)`.
- 제스처 변형: 탭=함몰 후 `elasticOut` 복원(~0.6s), 길게=함몰 유지, 드래그=손가락 근처 제어점만 변위, 꼬집기=장축 늘이기.

### 2. 배경 + 글로우
- `LinearGradient`(라벤더→페일핑크) 베이스 + 그 위 blurred radial glow 레이어(`ImageFiltered`/`BackdropFilter`, 낮은 alpha). 강조색은 의식별로만.

### 3. 의식 연출
- **파쇄:** 종이를 조각 파티클로 분해 → 누적 → `burst`로 폭죽 분산 + 페이드.
- **모닥불 연소:** 종이 마스크를 아래→위로 갉아내며(노이즈 경계) 불꽃 파티클 + ember 상승, 10~15s. 재로 소멸.
- **찢기:** 두 조각으로 분할, 찢김 경로는 약간 들쭉날쭉. 여러 번 가능. 위 스와이프로 조각 분산.
- **구김:** 셀수록 작아지는 공(반복 입력→scale↓, 주름 텍스처↑).
- **글자 모래:** 글리프를 점 입자로 분해해 흘러내림.

### 4. morph 전환
- 단계 전환은 페이드/모프(오브제→종이 솟아오름 등). 하드 컷 금지. `PageRouteBuilder`(빌더 제공) 위에 공유요소 모핑.

### 5. 물리
- 탄성 복원·관성은 `SpringSimulation`/`AnimationController`. 굴리기·던지기의 시각 운동은 builder의 센서 서비스 값을 가속도 벡터로 적분.

## 기술 원칙
- **곡선/타이밍:** 기본 `Curves.easeInOutCubic`, 탄성 `Curves.elasticOut`/스프링. 의식 연소는 길게(10~15s), 복원은 ~0.6s.
- **결정적 재현:** 파티클은 `Random(seed)` 시드 고정.
- **성능:** `shouldRepaint`를 값 비교로 정확히. `AnimatedBuilder`로 리빌드 범위 최소화. 입자 수·blur는 프레임 예산 내에서, 드랍 시 줄여 타협.
- **정리:** 모든 컨트롤러 `dispose()`. 비동기 네비게이션 전 `mounted` 체크.
- **플랫폼:** 무거운 셰이더보다 순수 Flutter. 센서 미지원 시 정적 폴백.

## 햅틱·사운드 동기화
- 비주얼 이벤트(벽 튕김, 종이 타는 진행도, 찢김 순간)와 `sensory-haptics`의 트리거가 어긋나면 촉각 환상이 깨진다. 공통 progress 값이나 콜백 시점을 sensory-haptics와 합의해 노출한다.

## 출력
- `lib/widgets/`·화면 내 모션 코드 + `_workspace/02_motion_{기능명}_notes.md`(모션, 곡선/타이밍 근거, 성능 주의, 햅틱 동기화 타임스탬프).
