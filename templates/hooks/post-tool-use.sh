#!/bin/bash
# =============================================================================
# PostToolUse Hook — 자동 수정 기록 + 코드 리뷰 + 오류 분기
# 1) 모든 Write/Edit를 change-log.md에 자동 기록
# 2) 코드 품질·보안·에러처리 체크
# 3) 오류 수에 따라 즉시 수정 또는 전문 에이전트 호출 분기
#
# [커스터마이징]
# - §4 "프로젝트 특화 체크": 프로젝트 API/라이브러리에 맞게 수정
# =============================================================================

set -uo pipefail

SHARED_DIR=".claude/hooks/shared"
CHANGE_LOG="$SHARED_DIR/change-log.md"
INPUT=$(cat)

# tool_name 추출
TOOL_NAME=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('tool_name', ''))
except:
    print('')
" 2>/dev/null || echo "")

if [ -z "$TOOL_NAME" ]; then
    TOOL_NAME=$(echo "$INPUT" | python -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('tool_name', ''))
except:
    print('')
" 2>/dev/null || echo "")
fi

# Write, Edit, Bash만 분석 대상
case "$TOOL_NAME" in
    Write|Edit|Bash) ;;
    *) exit 0 ;;
esac

# 필요한 필드 추출
FIELDS=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    ti = data.get('tool_input', {})
    print(ti.get('file_path', ti.get('command', '')))
    print('---SPLIT---')
    print(ti.get('content', ti.get('new_string', ti.get('command', ''))))
except:
    print('')
    print('---SPLIT---')
    print('')
" 2>/dev/null || echo "")

FILE_PATH=$(echo "$FIELDS" | sed -n '1p')
CONTENT=$(echo "$FIELDS" | sed '1,/---SPLIT---/d')

# 분석할 내용이 없으면 종료
if [ -z "$CONTENT" ]; then
    exit 0
fi

# =============================================================================
# 0. 수정 기록 자동 로깅
# =============================================================================
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")

if [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "Edit" ]; then
    if [ ! -f "$CHANGE_LOG" ]; then
        mkdir -p "$SHARED_DIR"
        echo "# 수정 기록 (Change Log)" > "$CHANGE_LOG"
        echo "" >> "$CHANGE_LOG"
    fi

    CONTENT_PREVIEW=$(echo "$CONTENT" | head -3 | tr '\n' ' ' | cut -c1-80)
    echo "| ${TIMESTAMP} | \`${TOOL_NAME}\` | \`${FILE_PATH}\` | \`${CONTENT_PREVIEW}...\` |" >> "$CHANGE_LOG"
fi

REMINDERS=""
ISSUE_COUNT=0

# 파일 확장자 추출
EXT=""
if [ -n "$FILE_PATH" ]; then
    EXT="${FILE_PATH##*.}"
fi

# =============================================================================
# 1. 위험한 작업 감지
# =============================================================================

# --- 파괴적 명령어 ---
if echo "$CONTENT" | grep -qiE 'rm\s+-rf|rmdir|DROP\s+TABLE|DELETE\s+FROM|truncate|format'; then
    REMINDERS+="  - 파괴적인 작업(삭제/포맷) 감지. 대상이 맞는지, 백업은 했는지 확인\n"
    ISSUE_COUNT=$((ISSUE_COUNT + 1))
fi

# --- 하드코딩된 자격증명 ---
if echo "$CONTENT" | grep -qiE 'password\s*=\s*"|api_key\s*=\s*"|secret\s*=\s*"|token\s*=\s*"'; then
    REMINDERS+="  - 비밀번호/API키/토큰이 코드에 하드코딩됨. 환경변수(.env)로 분리할 것\n"
    ISSUE_COUNT=$((ISSUE_COUNT + 1))
fi

# --- .env 파일 직접 수정 ---
if echo "$FILE_PATH" | grep -qiE '\.env$'; then
    REMINDERS+="  - .env 파일 수정됨. .gitignore에 .env가 포함되어 있는지 확인할 것\n"
    ISSUE_COUNT=$((ISSUE_COUNT + 1))
fi

# --- git force push ---
if echo "$CONTENT" | grep -qiE 'git\s+push.*--force|git\s+push.*-f\b|git\s+reset\s+--hard'; then
    REMINDERS+="  - force push/hard reset은 되돌리기 어려움. 정말 필요한 작업인지 확인\n"
    ISSUE_COUNT=$((ISSUE_COUNT + 1))
fi

# =============================================================================
# 2. Python 에러 처리 확인
# =============================================================================
if [ "$EXT" = "py" ]; then

    # --- API 호출에 try-except 없음 ---
    if echo "$CONTENT" | grep -qiE 'requests\.|aiohttp\.|httpx\.|fetch\(|urlopen'; then
        if ! echo "$CONTENT" | grep -qE 'try:|except'; then
            REMINDERS+="  - API/HTTP 호출에 try-except 없음. 네트워크 에러 시 크래시 가능\n"
            ISSUE_COUNT=$((ISSUE_COUNT + 1))
        fi
    fi

    # --- async 함수에서 블로킹 호출 ---
    if echo "$CONTENT" | grep -qE 'async\s+def'; then
        if echo "$CONTENT" | grep -qE 'requests\.get|requests\.post|time\.sleep\('; then
            REMINDERS+="  - async 함수 안에서 동기 블로킹 호출(requests/time.sleep) 감지. aiohttp/asyncio.sleep 사용 권장\n"
            ISSUE_COUNT=$((ISSUE_COUNT + 1))
        fi
    fi

    # --- 무한 루프 ---
    if echo "$CONTENT" | grep -qE 'while\s+(True|1):'; then
        if ! echo "$CONTENT" | grep -qE 'break|await.*sleep|asyncio\.sleep|time\.sleep'; then
            REMINDERS+="  - while True 루프에 break/sleep 없음. CPU 100% 또는 행업 가능\n"
            ISSUE_COUNT=$((ISSUE_COUNT + 1))
        fi
    fi
fi

# =============================================================================
# 3. 보안 체크
# =============================================================================

# --- SQL 인젝션 ---
if echo "$CONTENT" | grep -qiE "execute\s*\(\s*f\"|format\s*\(.*SELECT|format\s*\(.*INSERT|\+.*input.*SELECT"; then
    REMINDERS+="  - SQL 쿼리에 f-string/format 사용 감지. parameterized query로 변경 권장\n"
    ISSUE_COUNT=$((ISSUE_COUNT + 1))
fi

# --- 평문 통신 ---
if echo "$CONTENT" | grep -qiE 'http://[^l]|http://[^1]'; then
    REMINDERS+="  - HTTP 평문 통신 감지. 민감한 데이터가 있으면 HTTPS 사용 권장\n"
    ISSUE_COUNT=$((ISSUE_COUNT + 1))
fi

# --- 디버그 코드 잔존 ---
if echo "$CONTENT" | grep -qiE 'print\s*\(\s*["\x27]debug|#\s*TODO.*remove|#\s*FIXME|#\s*HACK|breakpoint\(\)'; then
    REMINDERS+="  - 디버그 코드/TODO 잔존 감지. 배포 전에 정리 필요\n"
    ISSUE_COUNT=$((ISSUE_COUNT + 1))
fi

# =============================================================================
# 4. 프로젝트 특화 체크
#    [커스터마이징] 프로젝트에서 쓰는 외부 API, 라이브러리에 맞게 추가하세요.
#    예시:
#    # --- Stripe API 레이트 리밋 ---
#    # if echo "$CONTENT" | grep -qiE 'stripe\.'; then
#    #     if ! echo "$CONTENT" | grep -qiE 'rate.*limit|retry|backoff'; then
#    #         REMINDERS+="  - Stripe API 호출에 retry/backoff 로직 확인\n"
#    #         ISSUE_COUNT=$((ISSUE_COUNT + 1))
#    #     fi
#    # fi
# =============================================================================

# =============================================================================
# 5. Bash 명령어 체크
# =============================================================================
if [ "$TOOL_NAME" = "Bash" ]; then
    if echo "$CONTENT" | grep -qiE 'rm\s+-rf\s+/|rm\s+-rf\s+\*|dd\s+if=|mkfs'; then
        REMINDERS+="  - 매우 위험한 명령어. 경로를 한 번 더 확인할 것\n"
        ISSUE_COUNT=$((ISSUE_COUNT + 1))
    fi

    if echo "$CONTENT" | grep -qiE 'pip install(?!.*-r)(?!.*requirements)'; then
        if ! echo "$CONTENT" | grep -qiE 'venv|virtualenv|conda'; then
            REMINDERS+="  - 글로벌 pip install 감지. 가상환경(venv) 안에서 실행하는 게 맞는지 확인\n"
            ISSUE_COUNT=$((ISSUE_COUNT + 1))
        fi
    fi
fi

# =============================================================================
# 6. 오류 수 기반 분기
# =============================================================================
ERROR_ACTION=""

if [ "$ISSUE_COUNT" -gt 0 ] && [ "$ISSUE_COUNT" -le 2 ]; then
    ERROR_ACTION="\n[자동 수정 권장] 발견된 이슈 ${ISSUE_COUNT}개 — 경미한 수준입니다. 위 항목을 지금 바로 수정하세요."
elif [ "$ISSUE_COUNT" -ge 3 ]; then
    ERROR_ACTION="\n[전문 에이전트 호출 권장] 발견된 이슈 ${ISSUE_COUNT}개 — 이슈가 많습니다.\n  → code-review-auditor 에이전트를 호출하여 전체 파일을 정밀 검토하세요.\n  → 파일: \`${FILE_PATH}\`"
fi

# =============================================================================
# 7. 수정 기록 로그 안내
# =============================================================================
LOG_NOTICE=""
if [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "Edit" ]; then
    LOG_NOTICE="\n[수정 기록] \`${FILE_PATH}\` → \`${CHANGE_LOG}\`에 자동 기록됨"
fi

# =============================================================================
# 8. 체크리스트·맥락노트 업데이트 리마인더
# =============================================================================
DOC_REMINDER=""

if ! echo "$FILE_PATH" | grep -qiE 'context-notes|checklist|change-log'; then
    if [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "Edit" ]; then
        DOC_REMINDER="\n[필수] 이 지시가 끝나면 반드시:\n  1. \`$SHARED_DIR/checklist.md\` — 완료 항목 1개 체크 + 다음 할 일 정리\n  2. \`$SHARED_DIR/context-notes.md\` — 결정사항과 이유 기록\n  ⚠ 체크리스트는 한 번에 여러 항목을 체크하지 마세요."
    fi
fi

# =============================================================================
# 9. 출력
# =============================================================================
ALL_CONTEXT=""

if [ -n "$REMINDERS" ]; then
    ALL_CONTEXT+="[코드 리뷰] 발견된 이슈: ${ISSUE_COUNT}개\n${REMINDERS}"
fi

if [ -n "$ERROR_ACTION" ]; then
    ALL_CONTEXT+="$ERROR_ACTION"
fi

if [ -n "$LOG_NOTICE" ]; then
    ALL_CONTEXT+="$LOG_NOTICE"
fi

if [ -n "$DOC_REMINDER" ]; then
    ALL_CONTEXT+="$DOC_REMINDER"
fi

if [ -n "$ALL_CONTEXT" ]; then
    cat <<HOOKJSON
{
  "hookSpecificOutput": {
    "additionalContext": "${ALL_CONTEXT}"
  }
}
HOOKJSON
else
    echo '{}'
fi

exit 0
