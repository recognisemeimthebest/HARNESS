#!/usr/bin/env bash
# =============================================================================
# Claude Code 오케스트레이션 하네스 부트스트랩 (Linux/macOS)
#
# 두 가지 모드:
#  (1) 로컬 모드 — 이 레포 안에서 실행 시 templates/ 디렉토리를 .claude/로 복사
#  (2) 원격 모드 — curl로 직접 다운받아 실행:
#      curl -fsSL https://raw.githubusercontent.com/recognisemeimthebest/HARNESS/main/install.sh | bash
#      (필요 시 RAW_BASE 환경변수로 다른 브랜치/포크 지정 가능)
#
# 동작:
#  - 대상 디렉토리(현재 작업 디렉토리, 또는 첫 번째 인자)에 .claude/ 생성
#  - settings.json, hooks/, skills/, agents/ 복사
#  - hooks/*.sh 실행권한 부여
#  - docs/PROJECT_SPEC.md 자리 (없으면 빈 템플릿 생성)
#  - shared/ 안의 3대 문서 자리 (없으면 빈 템플릿 생성)
# =============================================================================

set -euo pipefail

TARGET_DIR="${1:-$PWD}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/recognisemeimthebest/HARNESS/main}"

echo "================================================================"
echo "  Claude Code Orchestration Harness — install"
echo "  target: $TARGET_DIR"
echo "================================================================"

mkdir -p "$TARGET_DIR/.claude/hooks/shared"
mkdir -p "$TARGET_DIR/.claude/skills"
mkdir -p "$TARGET_DIR/.claude/agents"
mkdir -p "$TARGET_DIR/docs"

# --- 로컬/원격 자원 가져오기 헬퍼 ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]:-$0}" )" 2>/dev/null && pwd || true )"
LOCAL_TEMPLATES=""
if [ -n "$SCRIPT_DIR" ] && [ -d "$SCRIPT_DIR/templates" ]; then
    LOCAL_TEMPLATES="$SCRIPT_DIR/templates"
    echo "[mode] local — $LOCAL_TEMPLATES"
else
    echo "[mode] remote — $RAW_BASE"
    if ! command -v curl >/dev/null 2>&1; then
        echo "ERROR: 원격 모드는 curl이 필요합니다." >&2
        exit 1
    fi
fi

_fetch() {
    # $1: 상대경로 (templates/... 기준)
    # $2: 출력 경로 (절대)
    local rel="$1"
    local out="$2"
    mkdir -p "$(dirname "$out")"
    if [ -n "$LOCAL_TEMPLATES" ]; then
        cp "$LOCAL_TEMPLATES/${rel#templates/}" "$out"
    else
        curl -fsSL "$RAW_BASE/$rel" -o "$out"
    fi
}

# --- 1. settings.json ---
echo ""
echo "[1/5] settings.json …"
_fetch "templates/settings.json" "$TARGET_DIR/.claude/settings.json"

# --- 2. hooks ---
echo "[2/5] hooks …"
_fetch "templates/hooks/user-prompt-submit.sh" "$TARGET_DIR/.claude/hooks/user-prompt-submit.sh"
_fetch "templates/hooks/post-tool-use.sh"      "$TARGET_DIR/.claude/hooks/post-tool-use.sh"
chmod +x "$TARGET_DIR/.claude/hooks/user-prompt-submit.sh" "$TARGET_DIR/.claude/hooks/post-tool-use.sh"

# --- 3. skills ---
echo "[3/5] skills …"
_fetch "templates/skills/INDEX.md"               "$TARGET_DIR/.claude/skills/INDEX.md"
_fetch "templates/skills/ch01-python-quality.md" "$TARGET_DIR/.claude/skills/ch01-python-quality.md"
_fetch "templates/skills/ch02-skill-activation.md" "$TARGET_DIR/.claude/skills/ch02-skill-activation.md" || true

# --- 4. agents (템플릿 자리만, 실제 에이전트는 사용자가 커스터마이징) ---
echo "[4/5] agents (templates) …"
_fetch "templates/agents/domain-agent.md"  "$TARGET_DIR/.claude/agents/_domain-agent.template.md"
_fetch "templates/agents/auditor-agent.md" "$TARGET_DIR/.claude/agents/_auditor-agent.template.md"

# --- 5. 3대 문서 + 공유 파일 골격 ---
echo "[5/5] 3대 문서 자리 …"

if [ ! -f "$TARGET_DIR/docs/PROJECT_SPEC.md" ]; then
    cat > "$TARGET_DIR/docs/PROJECT_SPEC.md" <<'EOF'
# 프로젝트 기획서

> AI는 이 파일을 읽기만 한다. 수정은 사람 또는 전담 에이전트만.

## 목적
(이 프로젝트가 왜 존재하는지)

## 기능 명세
- (만들 기능 목록)

## 기술 스택
- (언어/프레임워크/라이브러리)

## 디렉토리 구조
```
.
├── ...
```

## 데이터 소스
- (API/DB/파일)

## 마일스톤
- [ ] Phase 1 —
- [ ] Phase 2 —

## 제약사항
- (꼭 지켜야 하는 규칙)
EOF
fi

if [ ! -f "$TARGET_DIR/.claude/hooks/shared/context-notes.md" ]; then
    cat > "$TARGET_DIR/.claude/hooks/shared/context-notes.md" <<'EOF'
# 맥락노트

> 작업 단위 완료 시 결정사항과 이유를 기록한다.

아직 없음
EOF
fi

if [ ! -f "$TARGET_DIR/.claude/hooks/shared/checklist.md" ]; then
    cat > "$TARGET_DIR/.claude/hooks/shared/checklist.md" <<'EOF'
# 체크리스트

> 한 번에 하나씩만 체크. `- [x]` 표시 후 다음 작업.

- [ ] (첫 번째 할 일을 적으세요)
EOF
fi

echo ""
echo "================================================================"
echo "  완료. 다음 단계:"
echo "    1. docs/PROJECT_SPEC.md 를 프로젝트에 맞게 작성"
echo "    2. .claude/agents/ 의 _*.template.md 를 복사해 실제 에이전트로 작성"
echo "    3. .claude/hooks/user-prompt-submit.sh §4·§7 을 프로젝트 도메인에 맞게 커스터마이징"
echo "    4. Claude Code를 이 디렉토리에서 실행하면 훅이 자동으로 동작"
echo "================================================================"
