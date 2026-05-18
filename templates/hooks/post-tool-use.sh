#!/usr/bin/env bash
# =============================================================================
# PostToolUse Hook — 자동 수정 기록 + Codex 사후 리뷰 (Linux/macOS)
#
# 트리거:  Write / Edit / Bash 도구 실행 후 자동 실행
# 1) 모든 Write/Edit → change-log.md 자동 기록
# 2) 정적 분석: 위험 작업/하드코딩/보안/Python 에러처리/Bash 위험명령
# 3) 외부 리뷰어 1차 리뷰 (이슈 / 수동 마커 / 대용량 / 민감 경로 → 트리거)
#    - 기본 REVIEWER=codex. 환경변수로 gemini/none 으로 전환 가능
#    - Codex가 1라운드 리뷰 → 메인 Claude가 그것을 보고 종합 판단
#
# [커스터마이징]
# - REVIEWER: codex | gemini | none (기본 codex)
# - CODEX_MODEL / GEMINI_MODEL: 모델명 오버라이드
# - MAX_CONTENT_LINES: 리뷰어에 전달할 최대 줄 수
# - SENSITIVE_KEYWORDS: 민감 파일 경로 키워드
# - §4 "프로젝트 특화 체크": 프로젝트에 맞게 추가
# =============================================================================

set -uo pipefail

CODEX_MODEL="${CODEX_MODEL:-}"        # 비우면 codex 기본 모델
GEMINI_MODEL="${GEMINI_MODEL:-gemini-3.1-pro-preview}"  # 폴백용
REVIEWER="${REVIEWER:-codex}"          # codex | gemini | none
MAX_CONTENT_LINES=400
SHARED_DIR=".claude/hooks/shared"
CHANGE_LOG="$SHARED_DIR/change-log.md"
SENSITIVE_KEYWORDS=(auth login payment billing security crypto token secret permission core middleware)

# =============================================================================
# 입력 파싱
# =============================================================================
INPUT=$(cat)

FIELDS=$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    ti = data.get('tool_input', {})
    print(data.get('tool_name', ''))
    print('---SPLIT---')
    print(ti.get('file_path', ti.get('command', '')))
    print('---SPLIT---')
    print(ti.get('content', ti.get('new_string', ti.get('command', ''))))
except Exception:
    print(''); print('---SPLIT---'); print(''); print('---SPLIT---'); print('')
" 2>/dev/null || printf '\n---SPLIT---\n\n---SPLIT---\n')

# 3-필드 분리
TOOL_NAME=$(printf '%s' "$FIELDS" | awk 'BEGIN{i=0} /^---SPLIT---$/{i++; next} i==0{print}')
FILE_PATH=$(printf '%s' "$FIELDS" | awk 'BEGIN{i=0} /^---SPLIT---$/{i++; next} i==1{print}')
CONTENT=$(printf '%s' "$FIELDS" | awk 'BEGIN{i=0} /^---SPLIT---$/{i++; next} i==2{print}')

case "$TOOL_NAME" in
    Write|Edit|Bash) ;;
    *) exit 0 ;;
esac

if [ -z "$CONTENT" ]; then
    exit 0
fi

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
EXT=""
if [ -n "$FILE_PATH" ]; then
    EXT="${FILE_PATH##*.}"
    # 슬래시가 있으면 확장자 추출 실패한 것
    case "$EXT" in */*) EXT="" ;; esac
fi

# =============================================================================
# 0. 수정 기록 자동 로깅
# =============================================================================
if [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "Edit" ]; then
    mkdir -p "$SHARED_DIR"
    if [ ! -f "$CHANGE_LOG" ]; then
        printf '# 수정 기록 (Change Log)\n\n' > "$CHANGE_LOG"
    fi
    PREVIEW=$(printf '%s' "$CONTENT" | head -n 3 | tr '\n' ' ' | cut -c1-80)
    printf '| %s | `%s` | `%s` | `%s...` |\n' "$TIMESTAMP" "$TOOL_NAME" "$FILE_PATH" "$PREVIEW" >> "$CHANGE_LOG"
fi

# =============================================================================
# 이슈 추적
# =============================================================================
REMINDERS=""
ISSUE_COUNT=0
HAS_CRITICAL=0

_add_issue() {
    REMINDERS+="  - $1"$'\n'
    ISSUE_COUNT=$((ISSUE_COUNT + 1))
}
_add_critical() {
    _add_issue "$1"
    HAS_CRITICAL=1
}

# =============================================================================
# 1. 위험한 작업 감지
# =============================================================================
if printf '%s' "$CONTENT" | grep -qiE 'rm\s+-rf|rmdir|DROP\s+TABLE|DELETE\s+FROM|truncate|format'; then
    _add_critical "파괴적인 작업(삭제/포맷) 감지. 대상이 맞는지, 백업은 했는지 확인"
fi

if printf '%s' "$CONTENT" | grep -qiE 'password\s*=\s*"|api_key\s*=\s*"|secret\s*=\s*"|token\s*=\s*"'; then
    _add_critical "비밀번호/API키/토큰 하드코딩 감지. 환경변수(.env)로 분리할 것"
fi

if printf '%s' "$FILE_PATH" | grep -qiE '\.env$'; then
    _add_issue ".env 파일 수정됨. .gitignore에 .env가 포함되어 있는지 확인할 것"
fi

if printf '%s' "$CONTENT" | grep -qiE 'git\s+push.*--force|git\s+push.*-f\b|git\s+reset\s+--hard'; then
    _add_issue "force push / hard reset은 되돌리기 어려움. 정말 필요한 작업인지 확인"
fi

# =============================================================================
# 2. Python 에러 처리
# =============================================================================
if [ "$EXT" = "py" ]; then
    if printf '%s' "$CONTENT" | grep -qiE 'requests\.|aiohttp\.|httpx\.|fetch\(|urlopen'; then
        if ! printf '%s' "$CONTENT" | grep -qE 'try:|except'; then
            _add_issue "API/HTTP 호출에 try-except 없음. 네트워크 에러 시 크래시 가능"
        fi
    fi
    if printf '%s' "$CONTENT" | grep -qE 'async\s+def'; then
        if printf '%s' "$CONTENT" | grep -qE 'requests\.get|requests\.post|time\.sleep\('; then
            _add_issue "async 함수 안에서 동기 블로킹 호출 감지. aiohttp/asyncio.sleep 사용 권장"
        fi
    fi
    if printf '%s' "$CONTENT" | grep -qE 'while\s+(True|1):'; then
        if ! printf '%s' "$CONTENT" | grep -qE 'break|await.*sleep|asyncio\.sleep|time\.sleep'; then
            _add_issue "while True 루프에 break/sleep 없음. CPU 100% 또는 행업 가능"
        fi
    fi
fi

# =============================================================================
# 3. 보안 체크
# =============================================================================
if printf '%s' "$CONTENT" | grep -qiE 'execute\s*\(\s*f"|format\s*\(.*SELECT|format\s*\(.*INSERT'; then
    _add_critical "SQL 쿼리에 f-string/format 사용. parameterized query로 변경 권장"
fi

if printf '%s' "$CONTENT" | grep -qiE 'http://[^l]'; then
    _add_issue "HTTP 평문 통신 감지. 민감한 데이터가 있으면 HTTPS 사용 권장"
fi

if printf '%s' "$CONTENT" | grep -qiE 'print\s*\(\s*["'\'']debug|#\s*TODO.*remove|#\s*FIXME|#\s*HACK|breakpoint\(\)'; then
    _add_issue "디버그 코드/TODO 잔존 감지. 배포 전에 정리 필요"
fi

# =============================================================================
# 4. 프로젝트 특화 체크 [커스터마이징]
# =============================================================================
# 예시: Stripe API retry 체크
# if printf '%s' "$CONTENT" | grep -qiE 'stripe\.'; then
#     if ! printf '%s' "$CONTENT" | grep -qiE 'retry|backoff|rate.*limit'; then
#         _add_issue "Stripe API 호출에 retry/backoff 로직 확인"
#     fi
# fi

# =============================================================================
# 5. Bash 명령어 체크
# =============================================================================
if [ "$TOOL_NAME" = "Bash" ]; then
    if printf '%s' "$CONTENT" | grep -qiE 'rm\s+-rf\s+/|rm\s+-rf\s+\*|dd\s+if=|mkfs'; then
        _add_critical "매우 위험한 명령어. 경로를 한 번 더 확인할 것"
    fi
fi

# =============================================================================
# 리뷰어 호출 함수 (Codex 우선, Gemini 폴백)
# =============================================================================
_invoke_codex() {
    # $1: prompt
    if ! command -v codex >/dev/null 2>&1; then
        printf '[Codex CLI 미설치]'
        return 1
    fi
    local prompt="$1"
    local result
    # read-only sandbox(기본), stdin 닫기, git 체크 스킵
    if [ -n "$CODEX_MODEL" ]; then
        result=$(codex exec --model "$CODEX_MODEL" --skip-git-repo-check "$prompt" </dev/null 2>&1)
    else
        result=$(codex exec --skip-git-repo-check "$prompt" </dev/null 2>&1)
    fi
    local rc=$?
    if [ $rc -ne 0 ] || [ -z "$result" ]; then
        printf '[Codex 호출 실패 (exit %d)]' "$rc"
        return 1
    fi
    # codex exec는 stderr에 헤더(workdir/model/...) + stdout에 본문을 섞어 출력함.
    # 헤더 라인 제거 (대략 8줄 이내) — "--------" 구분선 이후를 본문으로 간주
    printf '%s' "$result" | awk '
        BEGIN { body=0 }
        /^--------$/ { body=1; next }
        body { print }
    ' | sed '/^$/N;/^\n$/D'
}

_invoke_gemini() {
    if ! command -v gemini >/dev/null 2>&1; then
        printf '[Gemini CLI 미설치]'
        return 1
    fi
    local prompt="$1"
    local result
    result=$(gemini --model "$GEMINI_MODEL" -p "$prompt" 2>&1)
    local rc=$?
    if [ $rc -ne 0 ] || [ -z "$result" ]; then
        printf '[Gemini 호출 실패]'
        return 1
    fi
    printf '%s' "$result"
}

_invoke_reviewer() {
    # $1: prompt — REVIEWER 환경변수 기준으로 분기
    case "$REVIEWER" in
        codex)  _invoke_codex "$1" ;;
        gemini) _invoke_gemini "$1" ;;
        none)   printf '[REVIEWER=none — 자동 리뷰 비활성]'; return 1 ;;
        *)      _invoke_codex "$1" || _invoke_gemini "$1" ;;
    esac
}

# =============================================================================
# 6. Gemini 코드 리뷰 — 조건부 실행
# =============================================================================
GEMINI_SECTION=""
TRIGGER_GEMINI=0
TRIGGER_REASONS=""

if [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "Edit" ]; then

    LINE_COUNT=$(printf '%s' "$CONTENT" | wc -l | tr -d '[:space:]')
    if [ "$LINE_COUNT" -gt "$MAX_CONTENT_LINES" ]; then
        CODE_SAMPLE=$(printf '%s' "$CONTENT" | head -n "$MAX_CONTENT_LINES")
        TRUNCATED=" (상위 ${MAX_CONTENT_LINES} 줄)"
    else
        CODE_SAMPLE="$CONTENT"
        TRUNCATED=""
    fi

    # --- A) 정적 분석 이슈 ---
    if [ "$ISSUE_COUNT" -gt 0 ]; then
        TRIGGER_GEMINI=1
        TRIGGER_REASONS+="정적 분석 이슈 ${ISSUE_COUNT}개 | "
    fi

    # --- B) 수동 요청 마커 ---
    MANUAL_MARKER="$SHARED_DIR/.review-requested"
    MANUAL_MARKER_LEGACY="$SHARED_DIR/.gemini-review-requested"
    if [ -f "$MANUAL_MARKER" ] || [ -f "$MANUAL_MARKER_LEGACY" ]; then
        TRIGGER_GEMINI=1
        TRIGGER_REASONS+="수동 리뷰 요청 | "
        rm -f "$MANUAL_MARKER" "$MANUAL_MARKER_LEGACY"
    fi

    # --- C) 대용량 파일 ---
    if [ "$LINE_COUNT" -ge 400 ]; then
        TRIGGER_GEMINI=1
        TRIGGER_REASONS+="대용량 파일 (${LINE_COUNT}줄) | "
    fi

    # --- D) 민감 경로 ---
    for kw in "${SENSITIVE_KEYWORDS[@]}"; do
        if printf '%s' "$FILE_PATH" | grep -qi "$kw"; then
            TRIGGER_GEMINI=1
            TRIGGER_REASONS+="민감 경로 (${kw}) | "
            break
        fi
    done

    REASON_STR="${TRIGGER_REASONS% | }"

    # --- 외부 리뷰어 호출 (Codex 우선, Gemini 폴백) ---
    if [ "$TRIGGER_GEMINI" -eq 1 ]; then
        REVIEW_PROMPT=$(cat <<EOF
You are a code reviewer working alongside Claude (the main agent). Claude just wrote/edited the file below and will read your review and then give the user a synthesized verdict.

File: ${FILE_PATH}${TRUNCATED}
Trigger: ${REASON_STR}

Review the code. Check:
1. Quality and readability
2. Security (XSS, SQL injection, hardcoded credentials, path traversal, etc.)
3. Missing error handling / unchecked failure modes
4. Performance issues
5. Project / language best practices

For each issue, mark severity [CRITICAL] / [WARNING] / [INFO] and give a concrete fix direction.
Be concise — Claude will paraphrase, not quote you. Skip generic advice; focus on what is wrong in THIS code.
If the code looks fine, say so briefly.

--- code ---
${CODE_SAMPLE}
EOF
)
        REVIEW_OUTPUT=$(_invoke_reviewer "$REVIEW_PROMPT")

        GEMINI_SECTION=$(cat <<EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[${REVIEWER} 사후 리뷰] ${REASON_STR}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
${REVIEW_OUTPUT}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
→ [Claude 종합 판단] 위 리뷰를 본인의 시각과 합쳐 사용자에게 보고하세요:
   1. 진짜로 고쳐야 하는 이슈만 추려서 우선순위 매기기
   2. 의도적 설계/이미 처리됨 등 반론이 있으면 명시
   3. Codex 의견을 그대로 옮기지 말고 본인 판단으로 종합
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
)
    fi
fi

# =============================================================================
# 7. 출력 조립
# =============================================================================
ALL_CONTEXT=""

if [ -n "$REMINDERS" ]; then
    ALL_CONTEXT+="[정적 분석] 이슈 ${ISSUE_COUNT}개 감지"$'\n'
    ALL_CONTEXT+="$REMINDERS"
fi

if [ "$HAS_CRITICAL" -eq 1 ] || [ "$ISSUE_COUNT" -ge 3 ]; then
    ALL_CONTEXT+=$'\n'"[심각도 높음] 치명적 이슈 또는 이슈 ${ISSUE_COUNT}개 — Codex 리뷰까지 본 후 즉시 수정·재검토 권장"$'\n'
elif [ "$ISSUE_COUNT" -gt 0 ]; then
    ALL_CONTEXT+=$'\n'"[경미한 이슈] ${ISSUE_COUNT}개 — 위 항목을 바로 수정하세요"$'\n'
fi

if [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "Edit" ]; then
    ALL_CONTEXT+=$'\n'"[수정 기록] \`${FILE_PATH}\` → \`${CHANGE_LOG}\` 자동 기록됨"$'\n'
fi

if [ -n "$GEMINI_SECTION" ]; then
    ALL_CONTEXT+="$GEMINI_SECTION"
fi

# 체크리스트·맥락노트 리마인더
if [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "Edit" ]; then
    if ! printf '%s' "$FILE_PATH" | grep -qE 'context-notes|checklist|change-log'; then
        ALL_CONTEXT+=$'\n'"[필수] 작업 완료 시:"$'\n'
        ALL_CONTEXT+="  1. \`$SHARED_DIR/checklist.md\` — 완료 항목 체크 + 다음 할 일"$'\n'
        ALL_CONTEXT+="  2. \`$SHARED_DIR/context-notes.md\` — 결정사항과 이유 기록"$'\n'
        ALL_CONTEXT+="  ⚠ 체크리스트는 한 번에 여러 항목을 체크하지 마세요"$'\n'
    fi
fi

# JSON 출력 (additionalContext가 비어있지 않을 때만)
if [ -n "$ALL_CONTEXT" ]; then
    printf '%s' "$ALL_CONTEXT" | python3 -c "
import sys, json
text = sys.stdin.read()
print(json.dumps({'hookSpecificOutput': {'additionalContext': text}}, ensure_ascii=False))
"
else
    echo '{}'
fi

exit 0
