# 감정 오브제 명상 앱 — 정적 분석 + 테스트 실행
# Windows 셸은 PATH에 Flutter/Git이 없으므로 프리픽스를 먼저 세팅한다.
# 사용: powershell -File .claude/skills/flutter-qa/scripts/check.ps1

$ErrorActionPreference = "Continue"
$env:Path = "C:\Program Files\Git\cmd;C:\src\flutter\bin;" + $env:Path

Write-Host "=== flutter --version ==="
flutter --version

Write-Host "`n=== flutter pub get ==="
flutter pub get

Write-Host "`n=== flutter analyze ==="
flutter analyze
$analyzeExit = $LASTEXITCODE

Write-Host "`n=== flutter test ==="
flutter test
$testExit = $LASTEXITCODE

Write-Host "`n=== 요약 ==="
Write-Host "analyze exit: $analyzeExit  (0 = 경고 없음)"
Write-Host "test exit:    $testExit     (0 = 전체 통과)"
if ($analyzeExit -ne 0 -or $testExit -ne 0) {
  Write-Host "→ 실패/경고가 있습니다. 위 출력을 report에 첨부하세요."
  exit 1
}
Write-Host "→ analyze/test 모두 통과."
