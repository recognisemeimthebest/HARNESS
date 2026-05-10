# =============================================================================
# UserPromptSubmit Hook — 프롬프트 사전 분석기
#
# 1) 세션 첫 지시 → 기획서·맥락노트·체크리스트 브리핑
# 2) 매 지시 → 카테고리/복잡도/키워드 감지 → 스킬 챕터 주입
#
# [커스터마이징]
# - $SPEC_FILE: 프로젝트 기획서 경로
# - Section 4 "키워드 감지": 프로젝트 도메인에 맞게 수정
# - Section 7 "에이전트 추천": 프로젝트 에이전트에 맞게 수정
# =============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding            = [System.Text.Encoding]::UTF8

$SPEC_FILE   = "docs/PROJECT_SPEC.md"
$SHARED_DIR  = ".claude/hooks/shared"
$SKILLS_DIR  = ".claude/skills"

# =============================================================================
# 입력 파싱
# =============================================================================
$INPUT_DATA = [Console]::In.ReadToEnd()

try {
    $data      = $INPUT_DATA | ConvertFrom-Json
    $USER_MSG  = if ($data.prompt)     { $data.prompt }     elseif ($data.message) { $data.message } else { "" }
    $SESSION_ID = if ($data.session_id) { $data.session_id } else { "" }
} catch {
    $USER_MSG   = $INPUT_DATA
    $SESSION_ID = ""
}

if (-not $USER_MSG) { exit 0 }

$MSG_LOWER = $USER_MSG.ToLower()

# =============================================================================
# 1. 세션 시작 감지 — 첫 지시일 때 전체 브리핑
# =============================================================================
if ($SESSION_ID) {
    $SESSION_MARKER = "$env:TEMP\claude_harness_$SESSION_ID"

    if (-not (Test-Path $SESSION_MARKER)) {
        New-Item -ItemType File -Path $SESSION_MARKER -Force | Out-Null

        Write-Output ""
        Write-Output "================================================================"
        Write-Output "  SESSION START BRIEFING"
        Write-Output "================================================================"
        Write-Output ""

        # --- 기획서 ---
        Write-Output "### [기획서] $SPEC_FILE"
        if (Test-Path $SPEC_FILE) {
            Write-Output "프로젝트 기획서가 존재합니다. 전체 내용은 ``$SPEC_FILE``을 Read로 확인하세요."
        } else {
            Write-Output "(기획서 파일 없음)"
        }
        Write-Output ""

        # --- 맥락노트 ---
        Write-Output "### [맥락노트] 이전 작업 결정사항 & 자료 위치"
        $NOTES_FILE = "$SHARED_DIR/context-notes.md"
        if (Test-Path $NOTES_FILE) {
            $notes = Get-Content $NOTES_FILE -Raw -Encoding utf8
            # 실제 내용이 있을 때만 출력
            $meaningful = $notes -replace '(?m)^\s*$','' -replace '(?m)^#.*$','' -replace '(?m)^>.*$','' -replace '아직 없음',''
            if ($meaningful.Trim()) {
                Write-Output $notes
            } else {
                Write-Output "(아직 기록된 결정사항 없음)"
            }
        } else {
            Write-Output "(맥락노트 파일 없음)"
        }
        Write-Output ""

        # --- 체크리스트 ---
        Write-Output "### [체크리스트] 작업 진행 현황"
        $CHECK_FILE = "$SHARED_DIR/checklist.md"
        if (Test-Path $CHECK_FILE) {
            Get-Content $CHECK_FILE -Encoding utf8 | Write-Output

            Write-Output ""
            Write-Output "### [다음 할 일] 미완료 항목 첫 번째:"
            $nextTodo = Get-Content $CHECK_FILE -Encoding utf8 |
                        Where-Object { $_ -match '^\- \[ \]' } |
                        Select-Object -First 1
            if ($nextTodo) {
                Write-Output "  → $nextTodo"
            } else {
                Write-Output "  → 모든 항목 완료! 기획서에서 다음 Phase를 확인하세요."
            }
        } else {
            Write-Output "(체크리스트 파일 없음)"
        }

        Write-Output ""
        Write-Output "================================================================"
        Write-Output "  BRIEFING COMPLETE"
        Write-Output "  위 맥락을 참고하여 작업을 이어가세요."
        Write-Output "  작업이 끝나면 반드시 체크리스트·맥락노트를 업데이트하세요."
        Write-Output "================================================================"
        Write-Output ""
    }
}

# =============================================================================
# 2. 카테고리 분류
# =============================================================================
$CATEGORIES = [System.Collections.Generic.List[string]]::new()

if ($MSG_LOWER -match '만들|생성|구현|추가|작성|셋업|설치|초기화|코딩|코드')           { $CATEGORIES.Add("코드생성") }
if ($MSG_LOWER -match '수정|변경|바꿔|고쳐|업데이트|리팩토링|개선')                    { $CATEGORIES.Add("수정") }
if ($MSG_LOWER -match '오류|에러|버그|안됨|안 됨|실패|문제|깨짐|crash|error|debug')   { $CATEGORIES.Add("디버그") }
if ($MSG_LOWER -match '설명|뭐야|어떻게|왜|알려줘|확인|검토|분석')                    { $CATEGORIES.Add("설명요청") }
if ($MSG_LOWER -match '테스트|test|검증|확인해봐|돌려봐')                              { $CATEGORIES.Add("테스트") }
if ($MSG_LOWER -match 'commit|커밋|푸시|push|브랜치|branch|merge|git')               { $CATEGORIES.Add("Git작업") }
if ($MSG_LOWER -match '문서|기획|기록|정리|readme|doc')                               { $CATEGORIES.Add("문서화") }
if ($MSG_LOWER -match '설정|config|환경|세팅|hook|훅')                                { $CATEGORIES.Add("설정/환경") }

$CATEGORY_STR = if ($CATEGORIES.Count -gt 0) { $CATEGORIES -join ", " } else { "일반지시" }

# =============================================================================
# 3. 복잡도 판단
# =============================================================================
$WORD_COUNT  = ($USER_MSG -split '\s+' | Where-Object { $_ }).Count
$MODULE_COUNT = 0

$COMPLEXITY = if    ($WORD_COUNT -gt 30) { "복잡 (계획 수립 후 진행 권장)" }
              elseif ($WORD_COUNT -gt 12) { "중간" }
              else                        { "간단" }

# =============================================================================
# 4. 키워드 감지 → 스킬 챕터 매칭 [커스터마이징]
#    chapters/ 아래 파일명과 매칭되도록 수정하세요.
# =============================================================================
$MATCHED_CHAPTERS = [System.Collections.Generic.List[string]]::new()

# --- 범용: Python 품질 챕터 ---
if ($MSG_LOWER -match '보안|security|에러.*처리|error.*handl|exception|취약|xss|injection|테스트|test|async|await') {
    $MATCHED_CHAPTERS.Add("ch01-python-quality")
}
if ($MSG_LOWER -match '만들|생성|구현|수정|변경|리팩토링|오류|에러|버그|안됨|실패|크래시') {
    if ("ch01-python-quality" -notin $MATCHED_CHAPTERS) { $MATCHED_CHAPTERS.Add("ch01-python-quality") }
    $MODULE_COUNT++
}

# --- 예시: 도메인 챕터 (프로젝트에 맞게 추가) ---
# if ($MSG_LOWER -match '프론트|react|컴포넌트|ui|화면') {
#     $MATCHED_CHAPTERS.Add("chapters/01-frontend"); $MODULE_COUNT++
# }
# if ($MSG_LOWER -match 'api|서버|엔드포인트|라우트|미들웨어') {
#     $MATCHED_CHAPTERS.Add("chapters/02-backend"); $MODULE_COUNT++
# }
# if ($MSG_LOWER -match 'db|데이터베이스|쿼리|마이그레이션|스키마') {
#     $MATCHED_CHAPTERS.Add("chapters/03-database"); $MODULE_COUNT++
# }

# =============================================================================
# 5. 파일 경로 감지 → 추가 스킬 매핑
# =============================================================================
$FILE_PATHS = [regex]::Matches($USER_MSG, '[a-zA-Z0-9_/.~\\-]+\.(py|js|ts|json|md|ps1|sh|txt|yaml|yml|toml|cfg|env|sql)') |
              ForEach-Object { $_.Value } | Select-Object -First 5

foreach ($fpath in $FILE_PATHS) {
    if ($fpath -imatch '\.env|config|settings') {
        if ("ch01-python-quality" -notin $MATCHED_CHAPTERS) { $MATCHED_CHAPTERS.Add("ch01-python-quality") }
    }
    # 예시: 경로 기반 챕터 매핑
    # if ($fpath -match 'frontend|components') { $MATCHED_CHAPTERS.Add("chapters/01-frontend") }
}

# 복수 모듈 → 복잡도 상향
if    ($MODULE_COUNT -gt 2)                              { $COMPLEXITY = "복잡 (계획 수립 후 진행 권장)" }
elseif ($MODULE_COUNT -gt 1 -and $COMPLEXITY -eq "간단") { $COMPLEXITY = "중간" }

# =============================================================================
# 6. 코드 패턴 감지 [커스터마이징]
# =============================================================================
# 예시:
# if ($USER_MSG -match 'import React|from react')        { $MATCHED_CHAPTERS.Add("chapters/01-frontend") }
# if ($USER_MSG -match 'from fastapi|from flask')        { $MATCHED_CHAPTERS.Add("chapters/02-backend") }

# =============================================================================
# 7. 에이전트 추천 [커스터마이징]
# =============================================================================
$RECOMMENDED_AGENTS = [System.Collections.Generic.List[string]]::new()

if ($MSG_LOWER -match '기획|계획|스펙|마일스톤|milestone|phase|일정|로드맵|spec') {
    $RECOMMENDED_AGENTS.Add("project-planner")
}
# 예시:
# if ($MATCHED_CHAPTERS -contains "chapters/01-frontend") { $RECOMMENDED_AGENTS.Add("frontend-developer") }
# if ($MATCHED_CHAPTERS -contains "chapters/02-backend")  { $RECOMMENDED_AGENTS.Add("backend-developer") }

# =============================================================================
# 8. 이전 작업 이어하기 감지
# =============================================================================
$RESUME = ""
if ($MSG_LOWER -match '이어서|계속|어디까지|마저|하던|지난번|resume|continue') {
    $RESUME = "[RESUME] 이전 작업 이어하기 요청. 맥락노트(``$SHARED_DIR/context-notes.md``)와 체크리스트(``$SHARED_DIR/checklist.md``)를 먼저 확인하세요."
}

# =============================================================================
# 9. 출력
# =============================================================================
Write-Output "[프롬프트 분석] 카테고리: [$CATEGORY_STR] | 복잡도: $COMPLEXITY"

if ($FILE_PATHS) {
    Write-Output "감지된 경로: $($FILE_PATHS -join ', ')"
}

# 매칭된 스킬 챕터 로드
$UNIQUE_CHAPTERS = $MATCHED_CHAPTERS | Sort-Object -Unique
if ($UNIQUE_CHAPTERS.Count -gt 0) {
    Write-Output ""
    Write-Output "[스킬 챕터 로드]"
    foreach ($ch in $UNIQUE_CHAPTERS) {
        $chFile = "$SKILLS_DIR/${ch}.md"
        if (Test-Path $chFile) {
            Write-Output ""
            Write-Output "---"
            Get-Content $chFile -Encoding utf8 | Write-Output
        } else {
            Write-Output "  - 참고 챕터: $chFile (필요시 Read로 열어보세요)"
        }
    }
} else {
    Write-Output "특별한 키워드/패턴 감지 없음 → 일반 작업 모드"
    Write-Output "필요시 ``.claude/skills/INDEX.md``에서 관련 챕터를 찾아 로드하세요"
}

# 에이전트 추천
$UNIQUE_AGENTS = $RECOMMENDED_AGENTS | Sort-Object -Unique
if ($UNIQUE_AGENTS.Count -gt 0) {
    Write-Output ""
    Write-Output "[에이전트 추천]"
    foreach ($ag in $UNIQUE_AGENTS) {
        Write-Output "  → $ag (.claude/agents/${ag}.md)"
    }
    if ($UNIQUE_AGENTS.Count -gt 1) {
        Write-Output "  ⚠ 복수 도메인 감지 — 각 에이전트에 위임하여 병렬 처리를 고려하세요."
    }
    Write-Output "  → 작업 완료 후 평가 에이전트로 검증을 권장합니다."
}

if ($RESUME) {
    Write-Output ""
    Write-Output $RESUME
}

# =============================================================================
# 9-A. 복잡도별 계획 강제
# =============================================================================
if ($COMPLEXITY -match '복잡') {
    # current-task-plan.md 존재 여부 확인
    $PLAN_FILE = "$SHARED_DIR/current-task-plan.md"
    $planExists = Test-Path $PLAN_FILE

    Write-Output ""
    Write-Output "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    Write-Output "[계획 필수] 복잡한 작업이 감지되었습니다."
    Write-Output "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if (-not $planExists) {
        Write-Output "⚠ 계획 파일 없음 — 파일 수정 전에 반드시:"
        Write-Output "  1. 코드베이스를 먼저 탐색 (Read/Glob/Grep 사용)"
        Write-Output "  2. ``$PLAN_FILE`` 에 작성:"
        Write-Output "     - 접근 방식 및 이유"
        Write-Output "     - 단계별 실행 계획"
        Write-Output "     - 예상 영향 범위"
        Write-Output "  3. ``$SHARED_DIR/checklist.md`` 에 체크리스트 항목 추가"
        Write-Output "  4. 사용자 확인 후 순서대로 실행"
    } else {
        Write-Output "✓ 계획 파일 존재 — 계획대로 진행하세요."
        Write-Output "  현재 계획: ``$PLAN_FILE``"
        # 계획 파일 앞 5줄만 미리보기
        $planPreview = Get-Content $PLAN_FILE -Encoding utf8 | Select-Object -First 5
        $planPreview | ForEach-Object { Write-Output "  │ $_" }
    }
    Write-Output "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

} elseif ($COMPLEXITY -match '중간') {
    Write-Output ""
    Write-Output "[작업 워크플로우]"
    Write-Output "1. 기획서(``$SPEC_FILE``)를 참고하세요"
    Write-Output "2. 작업 완료 후 맥락노트·체크리스트 업데이트"
    Write-Output "3. 주요 작업은 평가 에이전트로 독립 검증하세요"
}

# =============================================================================
# 9-B. 현재 체크리스트 진행 상황 (매 지시마다)
# =============================================================================
$CHECK_FILE = "$SHARED_DIR/checklist.md"
if (Test-Path $CHECK_FILE) {
    $allItems  = (Get-Content $CHECK_FILE -Encoding utf8 | Where-Object { $_ -match '^\- \[' }).Count
    $doneItems = (Get-Content $CHECK_FILE -Encoding utf8 | Where-Object { $_ -match '^\- \[x\]' }).Count
    $nextItem  = Get-Content $CHECK_FILE -Encoding utf8 | Where-Object { $_ -match '^\- \[ \]' } | Select-Object -First 1

    if ($allItems -gt 0) {
        Write-Output ""
        Write-Output "[체크리스트] $doneItems / $allItems 완료"
        if ($nextItem) {
            Write-Output "  → 다음: $nextItem"
        } else {
            Write-Output "  → 모든 항목 완료!"
        }
    }
}

# =============================================================================
# 9-C. 맥락 유지 리마인더
# =============================================================================
Write-Output ""
Write-Output "[맥락 유지] 작업 완료 시 반드시:"
Write-Output "  · context-notes.md — 결정사항과 이유 기록 (나중에 왜 이렇게 했는지 남기기)"
Write-Output "  · checklist.md     — 완료 항목 [x] 체크, 새 항목 추가"
if ($COMPLEXITY -match '복잡') {
    Write-Output "  · current-task-plan.md — 계획 대비 실제 진행 차이 기록"
}

exit 0
