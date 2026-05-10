# =============================================================================
# PostToolUse Hook — 자동 수정 기록 + Gemini 코드 리뷰 + 토론 모드
#
# 트리거:  Write / Edit / Bash 도구 실행 후 자동 실행
# 일반:    Gemini 1차 리뷰 항상 실행
# 토론:    치명적 이슈 OR 이슈 3개 이상 → Gemini 2라운드 토론
#
# [커스터마이징]
# - $GEMINI_MODEL: 사용할 Gemini 모델명
# - $MAX_CONTENT_LINES: Gemini에 전달할 최대 줄 수
# - Section 4 "프로젝트 특화 체크": 프로젝트에 맞게 추가
# =============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding            = [System.Text.Encoding]::UTF8

$GEMINI_MODEL = "gemini-3.1-pro-preview"
$MAX_CONTENT_LINES = 400
$SHARED_DIR = ".claude/hooks/shared"
$CHANGE_LOG = "$SHARED_DIR/change-log.md"

# =============================================================================
# 입력 파싱
# =============================================================================
$INPUT_DATA = [Console]::In.ReadToEnd()

try {
    $data        = $INPUT_DATA | ConvertFrom-Json
    $TOOL_NAME   = $data.tool_name
    $ti          = $data.tool_input
    $FILE_PATH   = if ($ti.file_path) { $ti.file_path } elseif ($ti.command) { $ti.command } else { "" }
    $CONTENT     = if ($ti.content)   { $ti.content }   elseif ($ti.new_string) { $ti.new_string } elseif ($ti.command) { $ti.command } else { "" }
} catch {
    exit 0
}

if ($TOOL_NAME -notin @("Write", "Edit", "Bash")) { exit 0 }
if (-not $CONTENT)                                 { exit 0 }

$TIMESTAMP = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$EXT       = if ($FILE_PATH) { [System.IO.Path]::GetExtension($FILE_PATH).TrimStart('.') } else { "" }

# =============================================================================
# 0. 수정 기록 자동 로깅
# =============================================================================
if ($TOOL_NAME -in @("Write", "Edit")) {
    if (-not (Test-Path $CHANGE_LOG)) {
        New-Item -ItemType Directory -Force -Path $SHARED_DIR | Out-Null
        "# 수정 기록 (Change Log)`n" | Out-File -FilePath $CHANGE_LOG -Encoding utf8
    }
    $preview = (($CONTENT -split "`n") | Select-Object -First 3) -join " "
    if ($preview.Length -gt 80) { $preview = $preview.Substring(0, 80) }
    "| $TIMESTAMP | ``$TOOL_NAME`` | ``$FILE_PATH`` | ``$preview...`` |" |
        Add-Content -Path $CHANGE_LOG -Encoding utf8
}

# =============================================================================
# 이슈 추적
# =============================================================================
$REMINDERS   = [System.Collections.Generic.List[string]]::new()
$ISSUE_COUNT = 0
$HAS_CRITICAL = $false

# =============================================================================
# 1. 위험한 작업 감지
# =============================================================================
if ($CONTENT -match 'rm\s+-rf|rmdir|DROP\s+TABLE|DELETE\s+FROM|truncate|format') {
    $REMINDERS.Add("  - 파괴적인 작업(삭제/포맷) 감지. 대상이 맞는지, 백업은 했는지 확인")
    $ISSUE_COUNT++; $HAS_CRITICAL = $true
}

if ($CONTENT -imatch 'password\s*=\s*"|api_key\s*=\s*"|secret\s*=\s*"|token\s*=\s*"') {
    $REMINDERS.Add("  - 비밀번호/API키/토큰 하드코딩 감지. 환경변수(.env)로 분리할 것")
    $ISSUE_COUNT++; $HAS_CRITICAL = $true
}

if ($FILE_PATH -imatch '\.env$') {
    $REMINDERS.Add("  - .env 파일 수정됨. .gitignore에 .env가 포함되어 있는지 확인할 것")
    $ISSUE_COUNT++
}

if ($CONTENT -imatch 'git\s+push.*--force|git\s+push.*-f\b|git\s+reset\s+--hard') {
    $REMINDERS.Add("  - force push / hard reset은 되돌리기 어려움. 정말 필요한 작업인지 확인")
    $ISSUE_COUNT++
}

# =============================================================================
# 2. Python 에러 처리
# =============================================================================
if ($EXT -eq "py") {
    if ($CONTENT -imatch 'requests\.|aiohttp\.|httpx\.|fetch\(|urlopen') {
        if ($CONTENT -notmatch 'try:|except') {
            $REMINDERS.Add("  - API/HTTP 호출에 try-except 없음. 네트워크 에러 시 크래시 가능")
            $ISSUE_COUNT++
        }
    }
    if ($CONTENT -match 'async\s+def') {
        if ($CONTENT -match 'requests\.get|requests\.post|time\.sleep\(') {
            $REMINDERS.Add("  - async 함수 안에서 동기 블로킹 호출 감지. aiohttp/asyncio.sleep 사용 권장")
            $ISSUE_COUNT++
        }
    }
    if ($CONTENT -match 'while\s+(True|1):') {
        if ($CONTENT -notmatch 'break|await.*sleep|asyncio\.sleep|time\.sleep') {
            $REMINDERS.Add("  - while True 루프에 break/sleep 없음. CPU 100% 또는 행업 가능")
            $ISSUE_COUNT++
        }
    }
}

# =============================================================================
# 3. 보안 체크
# =============================================================================
if ($CONTENT -imatch 'execute\s*\(\s*f"|format\s*\(.*SELECT|format\s*\(.*INSERT') {
    $REMINDERS.Add("  - SQL 쿼리에 f-string/format 사용. parameterized query로 변경 권장")
    $ISSUE_COUNT++; $HAS_CRITICAL = $true
}

if ($CONTENT -imatch 'http://[^l]') {
    $REMINDERS.Add("  - HTTP 평문 통신 감지. 민감한 데이터가 있으면 HTTPS 사용 권장")
    $ISSUE_COUNT++
}

if ($CONTENT -imatch 'print\s*\(\s*["'']debug|#\s*TODO.*remove|#\s*FIXME|#\s*HACK|breakpoint\(\)') {
    $REMINDERS.Add("  - 디버그 코드/TODO 잔존 감지. 배포 전에 정리 필요")
    $ISSUE_COUNT++
}

# =============================================================================
# 4. 프로젝트 특화 체크 [커스터마이징]
# =============================================================================
# 예시: Stripe API retry 체크
# if ($CONTENT -imatch 'stripe\.') {
#     if ($CONTENT -notimatch 'retry|backoff|rate.*limit') {
#         $REMINDERS.Add("  - Stripe API 호출에 retry/backoff 로직 확인")
#         $ISSUE_COUNT++
#     }
# }

# =============================================================================
# 5. Bash 명령어 체크
# =============================================================================
if ($TOOL_NAME -eq "Bash") {
    if ($CONTENT -imatch 'rm\s+-rf\s+/|rm\s+-rf\s+\*|dd\s+if=|mkfs') {
        $REMINDERS.Add("  - 매우 위험한 명령어. 경로를 한 번 더 확인할 것")
        $ISSUE_COUNT++; $HAS_CRITICAL = $true
    }
}

# =============================================================================
# Gemini CLI 호출 함수
# =============================================================================
function Invoke-Gemini {
    param([string]$Prompt)

    # 임시 파일로 긴 프롬프트 전달 (CLI 길이 제한 우회)
    $tmp = [System.IO.Path]::GetTempFileName() + ".txt"
    try {
        $Prompt | Out-File -FilePath $tmp -Encoding utf8 -NoNewline
        $result = & gemini --model $GEMINI_MODEL -f $tmp 2>&1
        if ($LASTEXITCODE -ne 0 -or -not $result) {
            # -f 미지원 CLI 버전 대비 fallback: stdin 파이프
            $result = $Prompt | & gemini --model $GEMINI_MODEL 2>&1
        }
        return ($result -join "`n").Trim()
    } catch {
        return "[Gemini 호출 실패: $_]"
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

# =============================================================================
# 6. Gemini 코드 리뷰
# =============================================================================
$GEMINI_SECTION = ""

if ($TOOL_NAME -in @("Write", "Edit")) {

    # 너무 긴 파일은 앞부분만 전달
    $CODE_LINES  = $CONTENT -split "`n"
    $CODE_SAMPLE = ($CODE_LINES | Select-Object -First $MAX_CONTENT_LINES) -join "`n"
    $TRUNCATED   = if ($CODE_LINES.Count -gt $MAX_CONTENT_LINES) { " (상위 $MAX_CONTENT_LINES 줄)" } else { "" }

    # --- 1차 리뷰 (항상 실행) ---
    $ROUND1_PROMPT = @"
[1차 코드 리뷰]
파일: $FILE_PATH$TRUNCATED

아래 코드를 리뷰해줘. 다음 항목을 확인해:
1. 코드 품질 및 가독성
2. 보안 취약점 (XSS, SQL 인젝션, 하드코딩 자격증명 등)
3. 에러 처리 누락
4. 성능 이슈
5. 베스트 프랙티스 위반

심각도를 [CRITICAL] [WARNING] [INFO] 로 표시하고, 각 이슈마다 구체적인 수정 방향을 제시해줘.

--- 코드 ---
$CODE_SAMPLE
"@

    $ROUND1 = Invoke-Gemini -Prompt $ROUND1_PROMPT

    # --- 토론 모드: 치명적 이슈 OR 이슈 3개 이상 ---
    if ($HAS_CRITICAL -or $ISSUE_COUNT -ge 3) {

        $ROUND2_PROMPT = @"
[2차 리뷰 — 토론 모드]
파일: $FILE_PATH

너의 1차 리뷰 결과:
$ROUND1

이제 시니어 개발자(Claude)가 제기할 수 있는 반론을 스스로 검토해봐:
- "이 부분은 의도적인 설계다"
- "이 케이스는 외부에서 이미 처리된다"
- "컨텍스트상 실제 위험이 낮다"

반론을 검토한 뒤, 정말로 수정이 필요한 이슈만 추려서 최종 권고안을 정리해줘.
형식:
[최종 필수 수정] 반드시 고쳐야 할 항목
[최종 권장 수정] 시간이 되면 개선할 항목
[반론 수용] 1차 리뷰에서 제외한 항목과 이유
"@

        $ROUND2 = Invoke-Gemini -Prompt $ROUND2_PROMPT

        $GEMINI_SECTION = @"

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[Gemini 3.1 Pro — 토론 모드 활성화]
치명적 이슈 또는 이슈 $ISSUE_COUNT 개 감지
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[1차 리뷰]
$ROUND1

[2차 리뷰 — 반론 검토 후 최종 권고]
$ROUND2

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
→ [필수 수정] 항목부터 적용하세요.
→ 수정 완료 후 저장하면 Gemini가 재검증합니다.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
"@

    } else {

        $GEMINI_SECTION = @"

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[Gemini 3.1 Pro — 코드 리뷰]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
$ROUND1
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
"@
    }
}

# =============================================================================
# 7. 출력 조립
# =============================================================================
$ALL_CONTEXT = ""

if ($REMINDERS.Count -gt 0) {
    $ALL_CONTEXT += "[정적 분석] 이슈 ${ISSUE_COUNT}개 감지`n"
    $ALL_CONTEXT += ($REMINDERS -join "`n") + "`n"
}

if ($HAS_CRITICAL -or $ISSUE_COUNT -ge 3) {
    $ALL_CONTEXT += "`n[토론 모드] 치명적 이슈 또는 이슈 ${ISSUE_COUNT}개 — Gemini 2라운드 토론 진행됨`n"
} elseif ($ISSUE_COUNT -gt 0) {
    $ALL_CONTEXT += "`n[경미한 이슈] ${ISSUE_COUNT}개 — 위 항목을 바로 수정하세요`n"
}

if ($TOOL_NAME -in @("Write", "Edit")) {
    $ALL_CONTEXT += "`n[수정 기록] ``$FILE_PATH`` → ``$CHANGE_LOG`` 자동 기록됨`n"
}

if ($GEMINI_SECTION) {
    $ALL_CONTEXT += $GEMINI_SECTION
}

# 체크리스트·맥락노트 리마인더
if ($TOOL_NAME -in @("Write", "Edit") -and $FILE_PATH -notmatch 'context-notes|checklist|change-log') {
    $ALL_CONTEXT += "`n[필수] 작업 완료 시:`n"
    $ALL_CONTEXT += "  1. ``$SHARED_DIR/checklist.md`` — 완료 항목 체크 + 다음 할 일`n"
    $ALL_CONTEXT += "  2. ``$SHARED_DIR/context-notes.md`` — 결정사항과 이유 기록`n"
    $ALL_CONTEXT += "  ⚠ 체크리스트는 한 번에 여러 항목을 체크하지 마세요`n"
}

# JSON 출력
if ($ALL_CONTEXT) {
    @{
        hookSpecificOutput = @{
            additionalContext = $ALL_CONTEXT
        }
    } | ConvertTo-Json -Depth 3 -Compress
} else {
    '{}'
}

exit 0
