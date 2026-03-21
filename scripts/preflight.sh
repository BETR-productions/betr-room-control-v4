#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="BETR Room Control"
BETR_CORE_DIR="${BETR_CORE_DIR:-}"

if [[ -z "$BETR_CORE_DIR" || ! -d "$BETR_CORE_DIR" ]]; then
  for candidate in \
    "$PROJECT_DIR/../betr-core-v3" \
    "$PROJECT_DIR/../../betr-core-v3"
  do
    if [[ -d "$candidate" ]]; then
      BETR_CORE_DIR="$(cd "$candidate" >/dev/null 2>&1 && pwd)"
      break
    fi
  done
fi

if [[ -z "$BETR_CORE_DIR" || ! -d "$BETR_CORE_DIR" ]]; then
  echo "ERROR: Could not locate betr-core-v3. Set BETR_CORE_DIR."
  exit 1
fi

echo "== BËTR Room Control v4 preflight =="
echo "Core: $BETR_CORE_DIR"

if ! git -C "$BETR_CORE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: BETR_CORE_DIR '$BETR_CORE_DIR' is not a git checkout."
  exit 1
fi
if [[ -n "$(git -C "$BETR_CORE_DIR" status --porcelain)" ]]; then
  echo "ERROR: Core checkout '$BETR_CORE_DIR' has uncommitted changes."
  exit 1
fi

echo "Room Control SHA: $(git -C "$PROJECT_DIR" rev-parse HEAD)"
echo "Core SHA: $(git -C "$BETR_CORE_DIR" rev-parse HEAD)"

BETR_CORE_DIR="$BETR_CORE_DIR" swift build --package-path "$PROJECT_DIR"
BETR_CORE_DIR="$BETR_CORE_DIR" swift test --package-path "$PROJECT_DIR"
BETR_CORE_DIR="$BETR_CORE_DIR" "$PROJECT_DIR/scripts/build-app.sh" --configuration debug

CANDIDATE_APP="$PROJECT_DIR/build/artifacts/debug/${APP_NAME}.app"
if [[ -d "/Applications/${APP_NAME}.app" ]]; then
  "$PROJECT_DIR/scripts/validate-upgrade.sh" \
    --candidate "$CANDIDATE_APP" \
    --installed "/Applications/${APP_NAME}.app" \
    --skip-candidate-signature
fi
