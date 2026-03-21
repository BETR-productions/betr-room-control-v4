#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BETR_ROOT="$(cd "$REPO_DIR/.." && pwd)"
MARK_CLEAN=0

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<EOF
Usage: ./scripts/coderabbit-local-review.sh [options] [coderabbit review args]

Options:
  --mark-clean    Mark HEAD as clean in docs/reviews/ after a passing review
  --help          Show this message

Default scope when no args given:
  coderabbit review --type committed --base origin/main

Review reports are written to:
  docs/reviews/YYYY-MM-DD--coderabbit--<shortsha>.md
EOF
  exit 0
fi

# Consume --mark-clean before passing remaining args to coderabbit
if [[ "${1:-}" == "--mark-clean" ]]; then
  MARK_CLEAN=1
  shift
fi

if [[ "$#" -eq 0 ]]; then
  set -- --type committed --base origin/main
fi

CONFIG_FILES=()
for candidate in \
  "$BETR_ROOT/coderabbit/.coderabbit.yaml" \
  "$BETR_ROOT/coderabbit/profiles/macos-swift.md" \
  "$BETR_ROOT/AGENTS.md" \
  "$BETR_ROOT/CLAUDE.md" \
  "$REPO_DIR/.coderabbit.yaml" \
  "$REPO_DIR/AGENTS.md" \
  "$REPO_DIR/CLAUDE.md"
do
  if [[ -f "$candidate" ]]; then
    CONFIG_FILES+=("$candidate")
  fi
done

SHORT_SHA="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
REVIEW_DATE="$(date +%Y-%m-%d)"
REVIEW_DIR="$REPO_DIR/docs/reviews"
REVIEW_REPORT="$REVIEW_DIR/${REVIEW_DATE}--coderabbit--${SHORT_SHA}.md"

mkdir -p "$REVIEW_DIR"

echo "Running local CodeRabbit review..."
echo "Logs: $HOME/.coderabbit/logs"
echo "Report: $REVIEW_REPORT"
if (( ${#CONFIG_FILES[@]} > 0 )); then
  printf 'Config files:\n'
  printf '  - %s\n' "${CONFIG_FILES[@]}"
fi
echo

REVIEW_OUTPUT=""
if (( ${#CONFIG_FILES[@]} > 0 )); then
  REVIEW_OUTPUT="$(coderabbit review --plain --no-color -c "${CONFIG_FILES[@]}" "$@" 2>&1)"
else
  REVIEW_OUTPUT="$(coderabbit review --plain --no-color "$@" 2>&1)"
fi

echo "$REVIEW_OUTPUT"

# Write report
cat > "$REVIEW_REPORT" <<EOF
# CodeRabbit Review — ${REVIEW_DATE} — ${SHORT_SHA}

Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
Scope: $*

## Output

\`\`\`
${REVIEW_OUTPUT}
\`\`\`
EOF

if [[ "$MARK_CLEAN" -eq 1 ]]; then
  cat >> "$REVIEW_REPORT" <<'EOF'

## Status

CLEAN — no critical or warning findings after review pass.
Applied fixes: (none required)
EOF
  echo ""
  echo "Marked clean: $REVIEW_REPORT"
fi
