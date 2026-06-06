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

out vec4 fragColor;

void main() {
  vec2 fragCoord = FlutterFragCoord().xy;
  vec2 p = fragCoord - uCenter;

  // 두근거림(균일 펄스) + 미세 일렁임(각도·시간 기반 유기적 wobble).
  // (전역 swell/일렁임 강화는 제거 — 공 전체가 삼각형처럼 퍼지던 원인. 문지름 표현은
  //  아래 "손가락 자리 국소 함몰 + 둘레 rim"으로 국소화한다.)
  float ang = atan(p.y, p.x);
  float wob = 0.020 * sin(ang * 3.0 + uTime) + 0.012 * sin(ang * 2.0 - uTime * 0.7);
  float r = uRadius * uBreathe * (1.0 + wob);

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

  fragColor = vec4(color * edge, edge);
}
