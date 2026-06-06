#version 460 core
#include <flutter/runtime_effect.glsl>

// 감정 말랑이 — 3D 구 + 누른 지점 함몰(법선 변형) + 조명
//  + idle 두근거림(균일 펄스) + 미세 일렁임(유기적 wobble).
// 화면 평면에 그리지만 구 법선을 계산하고, 누른 자리에 "손가락 크기"의 가우시안
// 함몰을 주어 법선을 꺾은 뒤 조명을 적용 → 아무 데나 눌러도 그 자리가 3D로 쏙.

precision highp float;

uniform vec2 uSize;    // 0,1: 캔버스 크기(px)
uniform vec2 uCenter;  // 2,3: 공 중심(px)
uniform float uRadius; // 4: 기본 반지름(px)
uniform float uBreathe;// 5: 두근거림 배율(≈1±0.02)
uniform float uTime;   // 6: 일렁임용 위상(라디안)
// 7..21: 멀티터치 함몰점 5개 — 각 (x, y, depth). 손가락 여러 개로 동시에 누르면
// 그 지점들이 동시에 함몰된다(양 엄지로 두 군데 누르기 등). depth=0이면 무시.
uniform float uTouch[15];
// 22: 문지르기 세기(0~1). 문지르는 동안 푸딩/슬라임처럼 살짝 부풀어 퍼지고(swell)
// 일렁임이 커져 "지금 문지르고 있다"는 촉감을 살린다.
uniform float uStroke;
// 23: 굴림 회전각(rad). 표면 얼룩(또렷한 결)이 이 각도만큼 공 표면을 돌아
// "미끄러지지 않고 구르는" 단서를 준다. 조명/스페큘러는 월드 고정이라 영향 없음.
uniform float uRoll;
// 24,25: 굴림 운동 벡터(진행 방향 × 세기, 대략 0~1). 진행축으로 살짝 눌리고
//        늘어나는 rolling squash-stretch에 쓴다. 멈추면 0 → 변형 없음.
uniform vec2 uRollVel;

out vec4 fragColor;

const float PI = 3.14159265;

// 회전(2D). rolling squash-stretch를 진행축 기준으로 적용하기 위한 헬퍼.
mat2 rot2(float a) {
  float c = cos(a), s = sin(a);
  return mat2(c, -s, s, c);
}

void main() {
  vec2 fragCoord = FlutterFragCoord().xy;
  vec2 p = fragCoord - uCenter;

  // 두근거림(균일 펄스) + 미세 일렁임(각도·시간 기반 유기적 wobble).
  // (전역 swell/일렁임 강화는 제거 — 공 전체가 삼각형처럼 퍼지던 원인. 문지름 표현은
  //  아래 "손가락 자리 국소 함몰 + 둘레 rim"으로 국소화한다.)
  float ang = atan(p.y, p.x);
  float wob = 0.020 * sin(ang * 3.0 + uTime) + 0.012 * sin(ang * 2.0 - uTime * 0.7);
  float r = uRadius * uBreathe * (1.0 + wob);

  // ── rolling squash-stretch: 진행축으로 살짝 눌리고 직교축으로 늘어남 ──
  // 굴러가는 공이 진행 방향으로 약간 럭비공처럼 변형되는 운동감. 좌표 p를 진행축
  // 기준으로 역변환(샘플은 진행축 1+k 늘림 / 직교축 1-k*0.6 눌림)해 실루엣을 변형.
  // 멈추면 uRollVel=0 → ax=ay=1(원형 유지). 과하지 않게 상한 18%.
  float rollSpd = clamp(length(uRollVel), 0.0, 1.0);
  if (rollSpd > 0.001) {
    float ra = atan(uRollVel.y, uRollVel.x);
    float k = rollSpd * 0.18;            // 변형 세기(상한 18%)
    mat2 inv = rot2(-ra);
    vec2 pr = inv * p;                    // 진행축 정렬 좌표
    pr.x /= (1.0 + k);                   // 진행축: 늘어남(샘플은 압축)
    pr.y /= (1.0 - k * 0.6);             // 직교축: 눌림(샘플은 확장)
    p = rot2(ra) * pr;                    // 원좌표계로 복귀
    ang = atan(p.y, p.x);
  }

  float dist = length(p);
  float edge = smoothstep(r, r - 2.0, dist); // 1 안, 0 밖, 2px AA
  if (edge <= 0.0) {
    fragColor = vec4(0.0);
    return;
  }

  // 구 법선(뷰어 쪽 +z).
  vec2 nxy = p / r;
  float nz = sqrt(max(0.0, 1.0 - dot(nxy, nxy)));
  vec3 N = vec3(nxy, nz);

  // 멀티터치 함몰: 누름점 5개를 각각 "손가락 크기" 가우시안으로 법선을 꺾고,
  // 교란 벡터를 합산한다 → 여러 군데를 동시에 누르면 그 자리마다 따로 쏙 파인다.
  float sigma = uRadius * 0.30;        // 함몰 폭(엄지 크기 — 넓게, 잘 보이게 v18c)
  float sigmaB = uRadius * 0.55;       // 둘레 rim(부풂) 폭 — 더 넓게
  vec2 pert = vec2(0.0);
  float gsh = 0.0;                     // 함몰 안쪽 그늘용(가장 깊은 곳 기준)
  for (int i = 0; i < 5; i++) {
    vec2 tp = vec2(uTouch[i * 3], uTouch[i * 3 + 1]) - uCenter;
    float dpt = clamp(uTouch[i * 3 + 2], 0.0, 1.0);
    float di = length(p - tp);
    float gi = exp(-(di * di) / (2.0 * sigma * sigma)) * dpt;
    // (1) 손가락 자리 함몰(법선을 안쪽으로 꺾음). 진폭 0.85 — 넓힌 만큼 깊이 유지(v18c).
    pert += -(p - tp) / (sigma * sigma) * gi * (uRadius * 0.85);
    // (2) 문지를 때만(uStroke) 그 둘레가 솟는 rim — "눌린 자리 주변이 퍼지는" 슬라임
    //     느낌. 넓은 가우시안의 기울기를 반대 부호로 더해(법선 바깥쪽) 융기 띠를 만든다.
    float gb = exp(-(di * di) / (2.0 * sigmaB * sigmaB)) * dpt;
    pert += (p - tp) / (sigmaB * sigmaB) * gb * (uRadius * 0.22) * uStroke;
    gsh = max(gsh, gi);
  }
  N = normalize(vec3(N.xy + pert, N.z));

  // 조명: 좌상단 → 뷰어 쪽.
  vec3 L = normalize(vec3(-0.5, -0.6, 0.7));
  vec3 V = vec3(0.0, 0.0, 1.0);
  float diff = max(dot(N, L), 0.0);
  // 광택을 부드럽게: 지수를 낮춰(28→18) 날카로운 점반짝을 완화.
  float spec = pow(max(dot(reflect(-L, N), V), 0.0), 18.0);

  // 젤리 핑크 팔레트(전체적으로 더 밝게 — 어두워 보이던 문제 해소).
  vec3 hi = vec3(1.0, 0.97, 0.98);
  vec3 core = vec3(0.98, 0.80, 0.86);   // 밝은 핑크
  vec3 edgeC = vec3(0.94, 0.68, 0.77);  // 가장자리도 한 톤 밝게
  float t = dist / r;
  vec3 base = t < 0.42
      ? mix(hi, core, t / 0.42)
      : mix(core, edgeC, (t - 0.42) / 0.58);

  // 더 밝게: 앰비언트 0.86(어두운 면도 환하게) + 약한 확산/스펙큘러.
  vec3 color = base * (0.86 + 0.28 * diff) + vec3(spec) * 0.2;
  color *= (1.0 - 0.14 * gsh); // 함몰 안쪽 그늘(0.10→0.14, 더 깊어 보이게).

  // ── 굴러 보이는 표면 단서(대폭 강화): 구면 매핑된 얼룩/밴드가 표면을 넘어간다 ──
  // 화면 평면 normal을 구면 좌표로 본다: 위도 lat=asin(ny), 경도 lon=atan2(ny,nx).
  // 굴림 방향에 맞춰 경도/위도 한 축을 uRoll만큼 굴려(텍스처가 이동 반대로 흐름),
  // 그 위에 결정적 얼룩(longitude×latitude 격자)을 평가한다. 핵심은 "깊이감":
  //  · nz 게이트 → 앞면에서 또렷, 실루엣으로 갈수록 약해지고 뒷면(넘어간 자리) 사라짐.
  //  · 경도 미분(d lon/d screen)이 가장자리에서 커져 패턴이 압축되어 보임(구면 원근).
  // 진폭을 ±5% → ±0.22(음영 대비)로 키워 "굴러 넘어가는 점/밴드"가 확실히 보이게 한다.
  // 굴림 축(가로/세로)에 맞춰 경도가 도는 축을 정한다: rollShift가 가로면 경도, 세로면
  // 위도를 주로 굴리지만, 단순화를 위해 경도를 굴리고 위도는 화면 y로 둔다(좌우 굴리기
  // 기준). 위→아래 굴리기는 uRoll 부호로 점이 위/아래로 넘어가는 흐름이 보인다.
  float lon = atan(nxy.y, nxy.x) - uRoll; // 경도(이동 반대로 회전)
  float lat = asin(clamp(nxy.y, -1.0, 1.0)); // 위도(-PI/2..PI/2)
  // (A) 굵은 경도 점 5개: 표면을 따라 또렷하게 도는 마블 점. cos 합으로 lobe를 만들되
  //     지수로 또렷하게(밴딩) — 앞면 중앙에서 진하고 옆으로 압축.
  float spots = 0.0;
  spots += pow(max(0.0, cos(lon - 0.0)), 3.0) *  0.9;  // 진한 점
  spots += pow(max(0.0, cos(lon - 1.7)), 3.0) * -0.7;  // 밝은 점
  spots += pow(max(0.0, cos(lon - 3.0)), 3.0) *  0.8;  // 진한 점
  spots += pow(max(0.0, cos(lon - 4.4)), 3.0) * -0.6;  // 밝은 점
  spots += pow(max(0.0, cos(lon - 5.4)), 3.0) *  0.5;  // 진한 점
  // (B) 위도 변조: 점들이 적도 부근에 모이고 극으로 갈수록 옅어져(완전 띠 방지) +
  //     위도 밴드 한 줄 추가로 "구가 돈다"는 가로 흐름을 더 분명히.
  float latBand = cos(lat * 3.0 + uRoll * 0.0);
  spots *= (0.55 + 0.45 * cos(lat * 1.6));            // 적도 강조
  spots += latBand * 0.25;                             // 옅은 위도 밴드
  // (C) 구면 원근 압축: 가장자리(nz 작음)일수록 경도 변화가 급격 → 패턴이 압축되어
  //     보이게 nz로 한 번 더 변조하고, 뒷면은 완전히 사라지게 게이트.
  float faceGate = smoothstep(0.05, 0.55, nz);        // 앞면일수록 또렷, 실루엣 0
  float mottAmt = spots * 0.22 * faceGate;            // 진폭 ±0.22(확실히 보이게)
  color *= (1.0 + mottAmt);

  fragColor = vec4(color * edge, edge);
}
