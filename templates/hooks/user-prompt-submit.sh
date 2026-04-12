#!/bin/bash
# =============================================================================
# UserPromptSubmit Hook — 프롬프트 사전 분석기
# 1) 세션 첫 지시 → 기획서·맥락노트·체크리스트 브리핑
# 2) 매 지시 → 카테고리/키워드/경로/코드 감지 → 스킬 챕터 주입
#
# [커스터마이징]
# - SPEC_FILE: 프로젝트 기획서 경로
# - 키워드 감지 섹션(§4): 프로젝트 도메인에 맞게 수정
# - 에이전트 추천 섹션(§7): 프로젝트 에이전트에 맞게 수정
# =============================================================================

set -uo pipefail

SHARED_DIR=".claude/hooks/shared"
SKILLS_DIR=".claude/skills"
CHAPTERS_DIR="$SKILLS_DIR/chapters"
SPEC_FILE="docs/PROJECT_SPEC.md"

# --- stdin에서 JSON 읽기 ---
USER_INPUT=$(cat)

USER_MSG=$(echo "$USER_INPUT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('prompt', data.get('message', '')))
except:
    print('')
" 2>/dev/null || echo "")

if [ -z "$USER_MSG" ]; then
    USER_MSG=$(echo "$USER_INPUT" | python -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('prompt', data.get('message', '')))
except:
    print('')
" 2>/dev/null || echo "$USER_INPUT")
fi

if [ -z "$USER_MSG" ]; then
    exit 0
fi

# session_id 추출
SESSION_ID=$(echo "$USER_INPUT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('session_id', ''))
except:
    print('')
" 2>/dev/null || echo "")

MSG_LOWER=$(echo "$USER_MSG" | tr '[:upper:]' '[:lower:]')

# =============================================================================
# 1. 세션 시작 감지 — 첫 지시일 때 전체 브리핑
# =============================================================================
SESSION_MARKER="/tmp/claude_harness_${SESSION_ID:-default}"

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
        echo "프로젝트 기획서가 존재합니다. 전체 내용은 \`$SPEC_FILE\`을 Read로 확인하세요."
    else
        echo "(기획서 파일 없음)"
    fi
    echo ""

    # --- 맥락노트 ---
    echo "### [맥락노트] 이전 작업 결정사항 & 자료 위치"
    if [ -f "$SHARED_DIR/context-notes.md" ]; then
        NOTES=$(cat "$SHARED_DIR/context-notes.md")
        if echo "$NOTES" | grep -qvE '^\s*$|^#|^>|아직 없음'; then
            cat "$SHARED_DIR/context-notes.md"
        else
            echo "(아직 기록된 결정사항 없음)"
        fi
    else
        echo "(맥락노트 파일 없음)"
    fi
    echo ""

    # --- 체크리스트 ---
    echo "### [체크리스트] 작업 진행 현황"
    if [ -f "$SHARED_DIR/checklist.md" ]; then
        cat "$SHARED_DIR/checklist.md"

        # 다음 할 일 하이라이트
        echo ""
        echo "### [다음 할 일] 체크리스트에서 미완료 항목 중 첫 번째:"
        NEXT_TODO=$(grep -m 1 '^\- \[ \]' "$SHARED_DIR/checklist.md" 2>/dev/null || echo "")
        if [ -n "$NEXT_TODO" ]; then
            echo "  → $NEXT_TODO"
        else
            echo "  → 모든 항목 완료! 기획서에서 다음 Phase를 확인하세요."
        fi
    else
        echo "(체크리스트 파일 없음)"
    fi
    echo ""
    echo "================================================================"
    echo "  BRIEFING COMPLETE"
    echo "  위 맥락을 참고하여 작업을 이어가세요."
    echo "  작업이 끝나면 반드시 체크리스트·맥락노트를 업데이트하세요."
    echo "================================================================"
    echo ""
fi

# =============================================================================
# 2. 카테고리 분류
# =============================================================================
CATEGORIES=""

echo "$MSG_LOWER" | grep -qiE '만들|생성|구현|추가|작성|셋업|설치|초기화|코딩|코드' \
    && CATEGORIES+="코드생성,"
echo "$MSG_LOWER" | grep -qiE '수정|변경|바꿔|고쳐|업데이트|리팩토링|개선' \
    && CATEGORIES+="수정,"
echo "$MSG_LOWER" | grep -qiE '오류|에러|버그|안됨|안 됨|실패|문제|깨짐|crash|error|debug' \
    && CATEGORIES+="디버그,"
echo "$MSG_LOWER" | grep -qiE '설명|뭐야|어떻게|왜|알려줘|확인|검토|분석' \
    && CATEGORIES+="설명요청,"
echo "$MSG_LOWER" | grep -qiE '테스트|test|검증|확인해봐|돌려봐' \
    && CATEGORIES+="테스트,"
echo "$MSG_LOWER" | grep -qiE 'commit|커밋|푸시|push|브랜치|branch|merge|git' \
    && CATEGORIES+="Git작업,"
echo "$MSG_LOWER" | grep -qiE '문서|기획|기록|정리|readme|doc' \
    && CATEGORIES+="문서화,"
echo "$MSG_LOWER" | grep -qiE '설정|config|환경|세팅|설치|hook|훅' \
    && CATEGORIES+="설정/환경,"

if [ -z "$CATEGORIES" ]; then
    CATEGORIES="일반지시"
else
    CATEGORIES="${CATEGORIES%,}"
fi

# =============================================================================
# 3. 복잡도 판단
# =============================================================================
WORD_COUNT=$(echo "$USER_MSG" | wc -w)
COMPLEXITY="간단"

if [ "$WORD_COUNT" -gt 50 ]; then
    COMPLEXITY="복잡 (계획 수립 후 진행 권장)"
elif [ "$WORD_COUNT" -gt 20 ]; then
    COMPLEXITY="중간"
fi

MODULE_COUNT=0

# =============================================================================
# 4. 키워드 감지 → 스킬 챕터 매칭
#    [커스터마이징] 아래 블록을 프로젝트 도메인에 맞게 수정하세요.
#    예시: chapters/01-frontend, chapters/02-backend, chapters/03-database 등
# =============================================================================
MATCHED_CHAPTERS=""

# --- 예시: 도메인 챕터 매칭 (프로젝트에 맞게 수정) ---
# echo "$MSG_LOWER" | grep -qiE '프론트|react|컴포넌트|ui|화면' \
#     && MATCHED_CHAPTERS+=" chapters/01-frontend" && MODULE_COUNT=$((MODULE_COUNT + 1))
# echo "$MSG_LOWER" | grep -qiE 'api|서버|엔드포인트|라우트|미들웨어' \
#     && MATCHED_CHAPTERS+=" chapters/02-backend" && MODULE_COUNT=$((MODULE_COUNT + 1))
# echo "$MSG_LOWER" | grep -qiE 'db|데이터베이스|쿼리|마이그레이션|스키마' \
#     && MATCHED_CHAPTERS+=" chapters/03-database" && MODULE_COUNT=$((MODULE_COUNT + 1))

# --- 메타: Python 품질 (범용 — 보통 수정 불필요) ---
echo "$MSG_LOWER" | grep -qiE '보안|security|에러.*처리|error.*handl|exception|취약|xss|injection|테스트|test|async|await' \
    && MATCHED_CHAPTERS+=" ch01-python-quality"

# --- 요청 패턴 → Python 품질 자동 추가 ---
if echo "$MSG_LOWER" | grep -qiE '만들|생성|구현|수정|변경|리팩토링|오류|에러|버그|안됨|실패|크래시'; then
    echo "$MATCHED_CHAPTERS" | grep -q "ch01-python-quality" || MATCHED_CHAPTERS+=" ch01-python-quality"
fi

# 여러 모듈 → 복잡도 상향
if [ "$MODULE_COUNT" -gt 2 ]; then
    COMPLEXITY="복잡 (계획 수립 후 진행 권장)"
elif [ "$MODULE_COUNT" -gt 1 ] && [ "$COMPLEXITY" = "간단" ]; then
    COMPLEXITY="중간"
fi

# =============================================================================
# 5. 파일 경로 감지 → 추가 스킬 매핑
#    [커스터마이징] case 문을 프로젝트 구조에 맞게 수정하세요.
# =============================================================================
FILE_PATHS=$(echo "$USER_MSG" | grep -oE '[a-zA-Z0-9_/.~-]+\.(py|js|ts|json|md|sh|txt|yaml|yml|toml|cfg|env|sql)' | head -5)

if [ -n "$FILE_PATHS" ]; then
    while IFS= read -r fpath; do
        case "$fpath" in
            # 예시: 프로젝트 구조에 맞게 수정
            # *frontend/*|*components/*) MATCHED_CHAPTERS+=" chapters/01-frontend" ;;
            # *api/*|*routes/*) MATCHED_CHAPTERS+=" chapters/02-backend" ;;
            # *db/*|*migration*) MATCHED_CHAPTERS+=" chapters/03-database" ;;
            *.env*|*config*|*settings*) MATCHED_CHAPTERS+=" ch01-python-quality" ;;
        esac
    done <<< "$FILE_PATHS"
fi

# =============================================================================
# 6. 코드 패턴 감지 → 추가 스킬 매핑
#    [커스터마이징] 프로젝트에서 쓰는 라이브러리/프레임워크에 맞게 수정하세요.
# =============================================================================
# 예시:
# echo "$USER_MSG" | grep -qE 'import React|from react' \
#     && MATCHED_CHAPTERS+=" chapters/01-frontend"
# echo "$USER_MSG" | grep -qE 'from fastapi|from flask|from django' \
#     && MATCHED_CHAPTERS+=" chapters/02-backend"

# =============================================================================
# 7. 서브에이전트 추천
#    [커스터마이징] 프로젝트 에이전트에 맞게 수정하세요.
# =============================================================================
RECOMMENDED_AGENTS=""

# 예시: 스킬 챕터 매칭 결과 기반 에이전트 추천
# if echo "$MATCHED_CHAPTERS" | grep -q "chapters/01-frontend"; then
#     RECOMMENDED_AGENTS+=" frontend-developer"
# fi
# if echo "$MATCHED_CHAPTERS" | grep -q "chapters/02-backend"; then
#     RECOMMENDED_AGENTS+=" backend-developer"
# fi

# 기획/문서 카테고리 → project-planner
if echo "$MSG_LOWER" | grep -qiE '기획|계획|스펙|마일스톤|milestone|phase|일정|로드맵|spec'; then
    RECOMMENDED_AGENTS+=" project-planner"
fi

AGENT_COUNT=$(echo "$RECOMMENDED_AGENTS" | tr ' ' '\n' | grep -v '^$' | sort -u | wc -l)

# =============================================================================
# 8. 이전 작업 이어하기 감지
# =============================================================================
RESUME=""
if echo "$MSG_LOWER" | grep -qiE '이어서|계속|어디까지|마저|하던|지난번|resume|continue'; then
    RESUME="[RESUME] 이전 작업 이어하기 요청 감지. 맥락노트(\`$SHARED_DIR/context-notes.md\`)와 체크리스트(\`$SHARED_DIR/checklist.md\`)를 먼저 확인하세요."
fi

# =============================================================================
# 9. 출력
# =============================================================================
echo "[프롬프트 분석] 카테고리: [$CATEGORIES] | 복잡도: $COMPLEXITY"

if [ -n "$FILE_PATHS" ]; then
    echo "감지된 경로: $(echo "$FILE_PATHS" | tr '\n' ', ')"
fi

# 매칭된 스킬 챕터 로드
if [ -n "$MATCHED_CHAPTERS" ]; then
    UNIQUE=$(echo "$MATCHED_CHAPTERS" | tr ' ' '\n' | sort -u | grep -v '^$')

    echo ""
    echo "[스킬 챕터 로드]"

    for CH in $UNIQUE; do
        CH_FILE="$SKILLS_DIR/${CH}.md"
        if [ -f "$CH_FILE" ]; then
            echo ""
            echo "---"
            cat "$CH_FILE"
        else
            echo "  - 참고 챕터: $SKILLS_DIR/${CH}.md (필요시 Read로 열어보세요)"
        fi
    done
else
    echo "특별한 키워드/패턴 감지 없음 → 일반 작업 모드"
    echo "필요시 \`.claude/skills/INDEX.md\`에서 관련 챕터를 찾아 로드하세요"
fi

# 에이전트 추천
if [ -n "$RECOMMENDED_AGENTS" ]; then
    UNIQUE_AGENTS=$(echo "$RECOMMENDED_AGENTS" | tr ' ' '\n' | sort -u | grep -v '^$')
    AGENT_COUNT=$(echo "$UNIQUE_AGENTS" | wc -l)

    echo ""
    echo "[에이전트 추천]"
    for AG in $UNIQUE_AGENTS; do
        echo "  → $AG (.claude/agents/${AG}.md)"
    done

    if [ "$AGENT_COUNT" -gt 1 ]; then
        echo "  ⚠ 복수 도메인 감지 — 각 에이전트에 위임하여 병렬 처리를 고려하세요."
    fi

    echo "  → 작업 완료 후 평가 에이전트로 검증을 권장합니다."
fi

if [ -n "$RESUME" ]; then
    echo ""
    echo "$RESUME"
fi

# 복잡한 작업이면 워크플로우 안내
if echo "$COMPLEXITY" | grep -q "복잡\|중간"; then
    echo ""
    echo "[작업 워크플로우]"
    echo "1. 계획을 세우고 사용자에게 확인받으세요"
    echo "2. 기획서(\`$SPEC_FILE\`)를 참고하세요"
    echo "3. 작업 완료 후 맥락노트(\`$SHARED_DIR/context-notes.md\`)와 체크리스트(\`$SHARED_DIR/checklist.md\`) 업데이트"
    echo "4. 주요 작업은 평가 에이전트로 독립 검증하세요"
fi

# 항상 리마인더
echo ""
echo "[주의] 작업 단위 완료 시 맥락노트·체크리스트 업데이트 필수"

exit 0
