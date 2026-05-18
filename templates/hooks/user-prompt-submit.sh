#!/usr/bin/env bash
# =============================================================================
# UserPromptSubmit Hook — 프롬프트 사전 분석기 (Linux/macOS)
#
# 1) 세션 첫 지시 → 기획서·맥락노트·체크리스트·change-log 브리핑
# 2) 매 지시 → 카테고리/복잡도/모호성/키워드 감지 → 스킬 챕터 자동 주입
# 3) 복잡 작업 → current-task-plan.md 작성 강제
# 4) 매 지시 → 체크리스트 진행률 + Claude 행동 원칙 출력
#
# [커스터마이징]
# - SPEC_FILE: 프로젝트 기획서 경로
# - GEMINI_MODEL: 맥락노트 요약에 쓸 Gemini 모델
# - §4 키워드 감지 / §7 에이전트 추천: 프로젝트 도메인에 맞게 수정
# =============================================================================

set -uo pipefail

SHARED_DIR=".claude/hooks/shared"
SKILLS_DIR=".claude/skills"
SPEC_FILE="docs/PROJECT_SPEC.md"
GEMINI_MODEL="${GEMINI_MODEL:-gemini-3.1-pro-preview}"

# =============================================================================
# 입력 파싱 (stdin JSON)
# =============================================================================
USER_INPUT=$(cat)

PARSED=$(printf '%s' "$USER_INPUT" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    print(data.get('prompt', data.get('message', '')))
    print('---SPLIT---')
    print(data.get('session_id', ''))
except Exception:
    print('')
    print('---SPLIT---')
    print('')
" 2>/dev/null || printf '\n---SPLIT---\n\n')

USER_MSG=$(printf '%s' "$PARSED" | awk 'BEGIN{p=1} /^---SPLIT---$/{p=0; next} p{print}')
SESSION_ID=$(printf '%s' "$PARSED" | awk 'BEGIN{p=0} /^---SPLIT---$/{p=1; next} p{print; exit}')

# JSON 파싱 실패 시 원본 입력을 메시지로 간주
if [ -z "$USER_MSG" ]; then
    USER_MSG="$USER_INPUT"
fi

if [ -z "$USER_MSG" ]; then
    exit 0
fi

MSG_LOWER=$(printf '%s' "$USER_MSG" | tr '[:upper:]' '[:lower:]')

# =============================================================================
# Gemini 호출 헬퍼 (없으면 빈 문자열 반환)
# =============================================================================
_invoke_gemini() {
    # $1: prompt
    if ! command -v gemini >/dev/null 2>&1; then
        return 1
    fi
    local prompt="$1"
    gemini --model "$GEMINI_MODEL" -p "$prompt" 2>/dev/null \
        | grep -vE 'Warning|Ripgrep|true color|GrepTool' \
        || return 1
}

# =============================================================================
# 1. 세션 시작 감지 — 첫 지시일 때 전체 브리핑
# =============================================================================
SESSION_MARKER="${TMPDIR:-/tmp}/claude_harness_${SESSION_ID:-default}"

if [ -n "$SESSION_ID" ] && [ ! -f "$SESSION_MARKER" ]; then
    touch "$SESSION_MARKER"

    echo ""
    echo "================================================================"
    echo "  SESSION START BRIEFING"
    echo "================================================================"
    echo ""

    # --- 기획서 ---
    echo "### [기획서] $SPEC_FILE"
    if [ -f "$SPEC_FILE" ]; then
        echo "프로젝트 기획서 존재 → 필요 시 Read로 확인하세요."
    else
        echo "(기획서 파일 없음)"
    fi
    echo ""

    # --- 맥락노트 (길면 Gemini 요약, 없으면 최근 30줄) ---
    echo "### [맥락노트] 이전 결정사항"
    NOTES_FILE="$SHARED_DIR/context-notes.md"
    if [ -f "$NOTES_FILE" ]; then
        MEANINGFUL=$(grep -vE '^\s*$|^#|^>' "$NOTES_FILE" 2>/dev/null | tr -d '[:space:]')
        if [ -z "$MEANINGFUL" ] || [ "$MEANINGFUL" = "아직없음" ]; then
            echo "(아직 기록된 결정사항 없음)"
        else
            LINE_COUNT=$(wc -l < "$NOTES_FILE")
            if [ "$LINE_COUNT" -gt 40 ]; then
                echo "(맥락노트가 깁니다 — Gemini 요약 시도 중...)"
                SUMMARY_PROMPT=$(cat <<EOF
다음은 프로젝트 맥락 노트입니다. Claude가 새 세션을 시작할 때 읽을 수 있도록 핵심만 압축 요약해줘.
반드시 포함할 것:
- 실패했던 접근 방식과 이유
- 핵심 기술 결정사항
- 현재 미해결 이슈

절대 생략하면 안 되는 것: 실패 사례, 제약사항
형식: 불릿 포인트로 간결하게 (최대 15줄)

--- 맥락노트 원본 ---
$(cat "$NOTES_FILE")
EOF
)
                SUMMARY=$(_invoke_gemini "$SUMMARY_PROMPT" || true)
                if [ -n "$SUMMARY" ]; then
                    echo "[Gemini 요약]"
                    printf '%s\n' "$SUMMARY" | sed 's/^/  /'
                else
                    echo "[최근 30줄]"
                    tail -n 30 "$NOTES_FILE" | sed 's/^/  /'
                fi
            else
                cat "$NOTES_FILE"
            fi
        fi
    else
        echo "(맥락노트 파일 없음)"
    fi
    echo ""

    # --- 체크리스트 (항상 원본 전체) ---
    echo "### [체크리스트] 작업 진행 현황"
    CHECK_FILE="$SHARED_DIR/checklist.md"
    if [ -f "$CHECK_FILE" ]; then
        cat "$CHECK_FILE"
        echo ""
        echo "### [다음 할 일]"
        NEXT_TODO=$(grep -m1 '^- \[ \]' "$CHECK_FILE" 2>/dev/null || true)
        if [ -n "$NEXT_TODO" ]; then
            echo "  → $NEXT_TODO"
        else
            echo "  → 모든 항목 완료! 기획서에서 다음 Phase를 확인하세요."
        fi
    else
        echo "(체크리스트 파일 없음)"
    fi
    echo ""

    # --- change-log 롤링 윈도우 (최근 10개) ---
    CHANGE_LOG_FILE="$SHARED_DIR/change-log.md"
    if [ -f "$CHANGE_LOG_FILE" ]; then
        LOG_LINES=$(grep '^|' "$CHANGE_LOG_FILE" 2>/dev/null || true)
        if [ -n "$LOG_LINES" ]; then
            echo "### [최근 수정 이력] (최근 10개)"
            printf '%s\n' "$LOG_LINES" | tail -n 10 | sed 's/^/  /'
            echo ""
        fi
    fi

    echo "================================================================"
    echo "  BRIEFING COMPLETE — 위 맥락을 참고하여 작업을 이어가세요."
    echo "================================================================"
    echo ""
fi

# =============================================================================
# 2. 카테고리 분류
# =============================================================================
CATEGORIES=""

_match() { printf '%s' "$MSG_LOWER" | grep -qiE "$1"; }

_match '만들|생성|구현|추가|작성|셋업|설치|초기화|코딩|코드'        && CATEGORIES+="코드생성,"
_match '수정|변경|바꿔|고쳐|업데이트|리팩토링|개선'                 && CATEGORIES+="수정,"
_match '오류|에러|버그|안됨|안 됨|실패|문제|깨짐|crash|error|debug' && CATEGORIES+="디버그,"
_match '설명|뭐야|어떻게|왜|알려줘|확인|검토|분석'                 && CATEGORIES+="설명요청,"
_match '테스트|test|검증|확인해봐|돌려봐'                          && CATEGORIES+="테스트,"
_match 'commit|커밋|푸시|push|브랜치|branch|merge|git'             && CATEGORIES+="Git작업,"
_match '문서|기획|기록|정리|readme|doc'                            && CATEGORIES+="문서화,"
_match '설정|config|환경|세팅|hook|훅'                             && CATEGORIES+="설정/환경,"

if [ -z "$CATEGORIES" ]; then
    CATEGORY_STR="일반지시"
else
    CATEGORY_STR="${CATEGORIES%,}"
fi

# =============================================================================
# 3. 복잡도 판단 (PowerShell 기준: 12/30 단어)
# =============================================================================
WORD_COUNT=$(printf '%s' "$USER_MSG" | wc -w | tr -d '[:space:]')
COMPLEXITY="간단"

if [ "$WORD_COUNT" -gt 30 ]; then
    COMPLEXITY="복잡 (계획 수립 후 진행 권장)"
elif [ "$WORD_COUNT" -gt 12 ]; then
    COMPLEXITY="중간"
fi

MODULE_COUNT=0

# =============================================================================
# 3-B. 모호성 감지
# =============================================================================
AMBIGUOUS=0
AMBIGUITY_REASONS=""

# --- 지시 대명사 + 동작 동사, 그러나 구체적 대상 없음 ---
if _match '이거|저거|그거|이것|저것|그것|여기|저기|그쪽|요거'; then
    if _match '해줘|수정|바꿔|고쳐|삭제|지워|만들어|추가|넣어|바꿔줘'; then
        HAS_FILE_PATH=0
        HAS_NAME=0
        printf '%s' "$USER_MSG" | grep -qE '[a-zA-Z0-9_/\\.\-]{3,}\.(py|js|ts|md|json|ps1|sh|txt|yaml|yml|sql|cpp|h|c)' && HAS_FILE_PATH=1
        printf '%s' "$USER_MSG" | grep -qE '함수|클래스|변수|메서드|function|class|def |섹션|항목' && HAS_NAME=1
        if [ "$HAS_FILE_PATH" -eq 0 ] && [ "$HAS_NAME" -eq 0 ]; then
            AMBIGUOUS=1
            AMBIGUITY_REASONS+=$'\n  · 지시 대상 불명확 — 파일명·함수명·변수명을 구체적으로 알려주세요'
        fi
    fi
fi

# --- 지시가 너무 짧음 (3단어 이하 + 동작 동사) ---
if [ "$WORD_COUNT" -le 3 ] && _match '해줘|수정|고쳐|만들어|추가|삭제|바꿔|넣어|지워'; then
    AMBIGUOUS=1
    AMBIGUITY_REASONS+=$'\n  · 지시가 너무 짧습니다 — 무엇을, 어디서, 어떻게를 추가해주세요'
fi

# --- 광범위한 수정 범위 ---
if _match '전부.*수정|다\s.*바꿔|모든.*고쳐|전체.*변경|싹.*바꿔|다\s.*고쳐'; then
    AMBIGUOUS=1
    AMBIGUITY_REASONS+=$'\n  · 전체/전부 범위가 불명확 — 어떤 파일·모듈·기능인지 구체화해주세요'
fi

# =============================================================================
# 4. 키워드 감지 → 스킬 챕터 매칭 [커스터마이징]
# =============================================================================
MATCHED_CHAPTERS=""

# --- 범용: Python 품질 챕터 ---
if _match '보안|security|에러.*처리|error.*handl|exception|취약|xss|injection|테스트|test|async|await'; then
    MATCHED_CHAPTERS+=" ch01-python-quality"
fi
if _match '만들|생성|구현|수정|변경|리팩토링|오류|에러|버그|안됨|실패|크래시'; then
    echo "$MATCHED_CHAPTERS" | grep -q "ch01-python-quality" || MATCHED_CHAPTERS+=" ch01-python-quality"
    MODULE_COUNT=$((MODULE_COUNT + 1))
fi

# --- 예시: 도메인 챕터 (프로젝트에 맞게 추가) ---
# _match '프론트|react|컴포넌트|ui|화면'              && { MATCHED_CHAPTERS+=" chapters/01-frontend"; MODULE_COUNT=$((MODULE_COUNT+1)); }
# _match 'api|서버|엔드포인트|라우트|미들웨어'        && { MATCHED_CHAPTERS+=" chapters/02-backend";  MODULE_COUNT=$((MODULE_COUNT+1)); }
# _match 'db|데이터베이스|쿼리|마이그레이션|스키마'    && { MATCHED_CHAPTERS+=" chapters/03-database"; MODULE_COUNT=$((MODULE_COUNT+1)); }

# =============================================================================
# 5. 파일 경로 감지 → 추가 스킬 매핑
# =============================================================================
FILE_PATHS=$(printf '%s' "$USER_MSG" | grep -oE '[a-zA-Z0-9_/.~\-]+\.(py|js|ts|json|md|ps1|sh|txt|yaml|yml|toml|cfg|env|sql)' | head -5 || true)

if [ -n "$FILE_PATHS" ]; then
    while IFS= read -r fpath; do
        case "$fpath" in
            *.env*|*config*|*settings*)
                echo "$MATCHED_CHAPTERS" | grep -q "ch01-python-quality" || MATCHED_CHAPTERS+=" ch01-python-quality"
                ;;
            # 예시: 경로 기반 챕터 매핑
            # *frontend/*|*components/*) MATCHED_CHAPTERS+=" chapters/01-frontend" ;;
        esac
    done <<< "$FILE_PATHS"
fi

# 복수 모듈 → 복잡도 상향
if [ "$MODULE_COUNT" -gt 2 ]; then
    COMPLEXITY="복잡 (계획 수립 후 진행 권장)"
elif [ "$MODULE_COUNT" -gt 1 ] && [ "$COMPLEXITY" = "간단" ]; then
    COMPLEXITY="중간"
fi

# =============================================================================
# 6. 코드 패턴 감지 [커스터마이징]
# =============================================================================
# 예시:
# printf '%s' "$USER_MSG" | grep -qE 'import React|from react'   && MATCHED_CHAPTERS+=" chapters/01-frontend"
# printf '%s' "$USER_MSG" | grep -qE 'from fastapi|from flask'    && MATCHED_CHAPTERS+=" chapters/02-backend"

# =============================================================================
# 7. 에이전트 추천 [커스터마이징]
# =============================================================================
RECOMMENDED_AGENTS=""

if _match '기획|계획|스펙|마일스톤|milestone|phase|일정|로드맵|spec'; then
    RECOMMENDED_AGENTS+=" project-planner"
fi

# =============================================================================
# 8. 이전 작업 이어하기 감지
# =============================================================================
RESUME=""
if _match '이어서|계속|어디까지|마저|하던|지난번|resume|continue'; then
    RESUME="[RESUME] 이전 작업 이어하기 요청. 맥락노트(\`$SHARED_DIR/context-notes.md\`)와 체크리스트(\`$SHARED_DIR/checklist.md\`)를 먼저 확인하세요."
fi

# =============================================================================
# 8-B. 수동 리뷰 요청 감지 → 마커 파일 생성 (Codex 우선, Gemini fallback)
# =============================================================================
if _match 'codex.*리뷰|리뷰.*codex|gemini.*리뷰|리뷰.*gemini|코드.*리뷰해|리뷰해줘|검토.*해줘'; then
    mkdir -p "$SHARED_DIR"
    touch "$SHARED_DIR/.review-requested"
    echo ""
    echo "[리뷰 예약] 다음 파일 수정 시 Codex 사후 리뷰가 자동 실행됩니다."
fi

# =============================================================================
# 8-C. Codex 사전 위임 트리거 — 코드 생성 + 일정 분량 이상 시 강한 신호
# =============================================================================
CODEX_DELEGATE=0
CODEX_DELEGATE_REASON=""

# 코드 생성/구현 카테고리 + 단어 수 / 복잡도 기반
if echo "$CATEGORY_STR" | grep -q "코드생성" && [ "$WORD_COUNT" -ge 12 ]; then
    CODEX_DELEGATE=1
    CODEX_DELEGATE_REASON="코드 생성 작업 + 단어 ${WORD_COUNT}개 (분량이 늘어날 가능성)"
fi

# 사용자가 명시적으로 "Codex와 같이/둘 다/병렬" 같은 표현 사용
if _match 'codex.*같이|같이.*codex|둘 다.*짜|병렬.*짜|코덱스.*같이|같이.*코덱스|second opinion|다른 시각'; then
    CODEX_DELEGATE=1
    CODEX_DELEGATE_REASON="사용자 명시 협업 요청"
fi

# 새 파일/모듈/서비스 생성 키워드
if _match '새.*파일|새.*모듈|새.*서비스|새.*함수|처음부터|from scratch|새로.*짜|새로.*만들'; then
    if echo "$CATEGORY_STR" | grep -q "코드생성"; then
        CODEX_DELEGATE=1
        CODEX_DELEGATE_REASON="신규 코드 생성 (큰 분량 가능성 높음)"
    fi
fi

# 사용자가 명시적으로 거부한 경우 무효화
if _match '직접.*짜|간단.*하나|짧게.*하나|작은.*수정|한 줄|딱.*하나|claude만|클로드만'; then
    CODEX_DELEGATE=0
    CODEX_DELEGATE_REASON=""
fi

# =============================================================================
# 9. 출력
# =============================================================================
if [ "$AMBIGUOUS" -eq 1 ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "⚠ [모호한 지시 감지] 작업 전에 먼저 확인이 필요합니다:"
    printf '%s\n' "$AMBIGUITY_REASONS"
    echo "→ 바로 작업을 시작하지 말고, 위 항목을 사용자에게 먼저 질문하세요."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
fi

echo "[프롬프트 분석] 카테고리: [$CATEGORY_STR] | 복잡도: $COMPLEXITY"

if [ -n "$FILE_PATHS" ]; then
    echo "감지된 경로: $(printf '%s' "$FILE_PATHS" | tr '\n' ',' | sed 's/,$//')"
fi

# 매칭된 스킬 챕터 로드
UNIQUE_CHAPTERS=$(printf '%s' "$MATCHED_CHAPTERS" | tr ' ' '\n' | sort -u | grep -v '^$' || true)
if [ -n "$UNIQUE_CHAPTERS" ]; then
    echo ""
    echo "[스킬 챕터 로드]"
    while IFS= read -r CH; do
        CH_FILE="$SKILLS_DIR/${CH}.md"
        if [ -f "$CH_FILE" ]; then
            echo ""
            echo "---"
            cat "$CH_FILE"
        else
            echo "  - 참고 챕터: $CH_FILE (필요시 Read로 열어보세요)"
        fi
    done <<< "$UNIQUE_CHAPTERS"
else
    echo "특별한 키워드/패턴 감지 없음 → 일반 작업 모드"
    echo "필요시 \`.claude/skills/INDEX.md\`에서 관련 챕터를 찾아 로드하세요"
fi

# 에이전트 추천
UNIQUE_AGENTS=$(printf '%s' "$RECOMMENDED_AGENTS" | tr ' ' '\n' | sort -u | grep -v '^$' || true)
if [ -n "$UNIQUE_AGENTS" ]; then
    AGENT_COUNT=$(printf '%s\n' "$UNIQUE_AGENTS" | wc -l | tr -d '[:space:]')
    echo ""
    echo "[에이전트 추천]"
    while IFS= read -r AG; do
        echo "  → $AG (.claude/agents/${AG}.md)"
    done <<< "$UNIQUE_AGENTS"
    if [ "$AGENT_COUNT" -gt 1 ]; then
        echo "  ⚠ 복수 도메인 감지 — 각 에이전트에 위임하여 병렬 처리를 고려하세요."
    fi
    echo "  → 작업 완료 후 평가 에이전트로 검증을 권장합니다."
fi

if [ -n "$RESUME" ]; then
    echo ""
    echo "$RESUME"
fi

# =============================================================================
# 9-A. 복잡도별 계획 강제
# =============================================================================
if echo "$COMPLEXITY" | grep -q "복잡"; then
    PLAN_FILE="$SHARED_DIR/current-task-plan.md"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "[계획 필수] 복잡한 작업이 감지되었습니다."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ ! -f "$PLAN_FILE" ]; then
        echo "⚠ 계획 파일 없음 — 파일 수정 전에 반드시:"
        echo "  1. 코드베이스를 먼저 탐색 (Read/Glob/Grep 사용)"
        echo "  2. \`$PLAN_FILE\` 에 작성:"
        echo "     - 접근 방식 및 이유"
        echo "     - 단계별 실행 계획"
        echo "     - 예상 영향 범위"
        echo "  3. \`$SHARED_DIR/checklist.md\` 에 체크리스트 항목 추가"
        echo "  4. 사용자 확인 후 순서대로 실행"
    else
        echo "✓ 계획 파일 존재 — 계획대로 진행하세요."
        echo "  현재 계획: \`$PLAN_FILE\`"
        head -n 5 "$PLAN_FILE" | sed 's/^/  │ /'
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
elif [ "$COMPLEXITY" = "중간" ]; then
    echo ""
    echo "[작업 워크플로우]"
    echo "1. 기획서(\`$SPEC_FILE\`)를 참고하세요"
    echo "2. 작업 완료 후 맥락노트·체크리스트 업데이트"
    echo "3. 주요 작업은 평가 에이전트로 독립 검증하세요"
fi

# =============================================================================
# 9-B. 현재 체크리스트 진행 상황 (매 지시마다)
# =============================================================================
CHECK_FILE="$SHARED_DIR/checklist.md"
if [ -f "$CHECK_FILE" ]; then
    ALL_ITEMS=$(grep -cE '^- \[' "$CHECK_FILE" 2>/dev/null || echo 0)
    DONE_ITEMS=$(grep -cE '^- \[x\]' "$CHECK_FILE" 2>/dev/null || echo 0)
    NEXT_ITEM=$(grep -m1 '^- \[ \]' "$CHECK_FILE" 2>/dev/null || true)
    if [ "$ALL_ITEMS" -gt 0 ]; then
        echo ""
        echo "[체크리스트] $DONE_ITEMS / $ALL_ITEMS 완료"
        if [ -n "$NEXT_ITEM" ]; then
            echo "  → 다음: $NEXT_ITEM"
        else
            echo "  → 모든 항목 완료!"
        fi
    fi
fi

# =============================================================================
# 9-C. 맥락 유지 리마인더
# =============================================================================
echo ""
echo "[맥락 유지] 작업 완료 시 반드시:"
echo "  · context-notes.md — 결정사항과 이유 기록 (나중에 왜 이렇게 했는지 남기기)"
echo "  · checklist.md     — 완료 항목 [x] 체크, 새 항목 추가"
if echo "$COMPLEXITY" | grep -q "복잡"; then
    echo "  · current-task-plan.md — 계획 대비 실제 진행 차이 기록"
fi

# =============================================================================
# 9-D. Claude 행동 원칙 (매 지시마다)
# =============================================================================
echo ""
echo "[Claude 행동 원칙]"
echo "  · 지시가 모호하면 → 추측해서 진행하지 말고 먼저 질문하세요"
echo "  · 사용자 전제가 틀렸으면 → 작업 전에 먼저 설명하고 확인을 받으세요"
echo "  · 더 나은 방법이 있으면 → 제안하고 선택권을 주세요"

# =============================================================================
# 9-E. Codex 자동 협업 원칙 (코드 생성 시 자동 위임)
# =============================================================================
echo ""
echo "[Codex 자동 협업 원칙]"
echo "  · 코드를 새로 짜야 하고 분량이 50줄 이상 예상되거나 신규 파일/모듈 생성이면"
echo "    → 즉시 codex 서브에이전트(subagent_type: codex)에 초안을 위임"
echo "    → Codex 응답을 받으면: (1) 요구사항 충족 확인 (2) 보안/에러처리 검수"
echo "       (3) 프로젝트 컨벤션 정렬 (4) 본인이 추가 수정·통합 후 최종 작성"
echo "  · 작은 수정(한 줄, 이름 바꾸기, 디버그/print 추가)은 Codex 호출 없이 직접"
echo "  · 사용자가 '직접 짜', '간단히' 등을 명시하면 위임하지 말 것"
echo "  · 사후 리뷰: 파일 작성 후 Codex 1차 리뷰가 자동 실행됨. Codex 의견을 본 뒤"
echo "    본인 시각을 더해 종합 판단을 사용자에게 보고하세요 (Codex 말 그대로 옮기지 X)"

# Codex 사전 위임 트리거 발동 시 강한 신호
if [ "$CODEX_DELEGATE" -eq 1 ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "▶ [Codex 사전 위임 발동] $CODEX_DELEGATE_REASON"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "이번 작업은 Codex와 협업이 권장됩니다."
    echo "1) 메인 Claude가 요구사항을 1-2문장으로 정리"
    echo "2) codex 서브에이전트 호출 (Agent 툴, subagent_type: codex)"
    echo "3) Codex 초안 회수 → 검수·수정 → 최종 파일 작성"
    echo "사용자가 '직접 짜'를 명시한 경우엔 이 안내를 무시하세요."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi

exit 0
