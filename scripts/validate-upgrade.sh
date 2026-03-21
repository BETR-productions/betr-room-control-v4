#!/bin/bash
set -euo pipefail

EXPECTED_BUNDLE_ID="com.betr.room-control-v4"
EXPECTED_TEAM_ID="Y8WQ4W4L59"
EXPECTED_RELEASE_REPO="BETR-productions/betr-room-control-v4"
CANDIDATE_APP=""
INSTALLED_APP="/Applications/BETR Room Control.app"
SKIP_CANDIDATE_SIGNATURE=0

usage() {
  cat <<EOF
Usage: $(basename "$0") --candidate <app> [options]

Options:
  --candidate <app>              Candidate app bundle to validate
  --installed <app>              Installed app bundle to compare against. Default: /Applications/BETR Room Control.app
  --skip-candidate-signature     Skip candidate Team ID validation
  --help                         Show this message
EOF
}

read_plist_value() {
  local app_path="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$app_path/Contents/Info.plist"
}

read_team_id() {
  local app_path="$1"
  codesign -dv "$app_path" 2>&1 | awk -F= '/TeamIdentifier=/{print $2}'
}

normalize_version() {
  local raw="$1"
  IFS='.' read -r -a parts <<< "$raw"
  printf "%04d%04d%04d%04d\n" "${parts[0]:-0}" "${parts[1]:-0}" "${parts[2]:-0}" "${parts[3]:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --candidate)
      CANDIDATE_APP="$2"
      shift 2
      ;;
    --installed)
      INSTALLED_APP="$2"
      shift 2
      ;;
    --skip-candidate-signature)
      SKIP_CANDIDATE_SIGNATURE=1
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$CANDIDATE_APP" ]]; then
  echo "ERROR: --candidate is required."
  usage
  exit 1
fi

if [[ ! -d "$CANDIDATE_APP" ]]; then
  echo "ERROR: Candidate app not found: $CANDIDATE_APP"
  exit 1
fi

# If no v4 is installed yet, skip the installed-version check
if [[ ! -d "$INSTALLED_APP" ]]; then
  echo "No installed app found at $INSTALLED_APP — skipping upgrade comparison."

  CANDIDATE_BUNDLE_ID="$(read_plist_value "$CANDIDATE_APP" CFBundleIdentifier)"
  if [[ "$CANDIDATE_BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
    echo "ERROR: Candidate bundle ID mismatch. Found=$CANDIDATE_BUNDLE_ID Expected=$EXPECTED_BUNDLE_ID"
    exit 1
  fi

  CANDIDATE_RELEASE_REPO="$(read_plist_value "$CANDIDATE_APP" BETRReleaseRepository)"
  if [[ "$CANDIDATE_RELEASE_REPO" != "$EXPECTED_RELEASE_REPO" ]]; then
    echo "ERROR: Candidate release repo mismatch. Found=$CANDIDATE_RELEASE_REPO Expected=$EXPECTED_RELEASE_REPO"
    exit 1
  fi

  if [[ "$SKIP_CANDIDATE_SIGNATURE" -ne 1 ]]; then
    CANDIDATE_TEAM_ID="$(read_team_id "$CANDIDATE_APP")"
    if [[ "$CANDIDATE_TEAM_ID" != "$EXPECTED_TEAM_ID" ]]; then
      echo "ERROR: Candidate Team ID mismatch. Found=$CANDIDATE_TEAM_ID Expected=$EXPECTED_TEAM_ID"
      exit 1
    fi
  fi

  CANDIDATE_VERSION="$(read_plist_value "$CANDIDATE_APP" CFBundleShortVersionString)"
  echo "Candidate-only validation passed"
  echo "  candidate: $CANDIDATE_APP ($CANDIDATE_VERSION)"
  echo "  bundle id: $EXPECTED_BUNDLE_ID"
  echo "  release repo: $EXPECTED_RELEASE_REPO"
  exit 0
fi

CANDIDATE_BUNDLE_ID="$(read_plist_value "$CANDIDATE_APP" CFBundleIdentifier)"
INSTALLED_BUNDLE_ID="$(read_plist_value "$INSTALLED_APP" CFBundleIdentifier)"
CANDIDATE_VERSION="$(read_plist_value "$CANDIDATE_APP" CFBundleShortVersionString)"
INSTALLED_VERSION="$(read_plist_value "$INSTALLED_APP" CFBundleShortVersionString)"
CANDIDATE_RELEASE_REPO="$(read_plist_value "$CANDIDATE_APP" BETRReleaseRepository)"
INSTALLED_TEAM_ID="$(read_team_id "$INSTALLED_APP")"

if [[ "$CANDIDATE_BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" || "$INSTALLED_BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
  echo "ERROR: Bundle ID mismatch. Candidate=$CANDIDATE_BUNDLE_ID Installed=$INSTALLED_BUNDLE_ID Expected=$EXPECTED_BUNDLE_ID"
  exit 1
fi

if [[ "$INSTALLED_TEAM_ID" != "$EXPECTED_TEAM_ID" ]]; then
  echo "ERROR: Installed Team ID mismatch. Found=$INSTALLED_TEAM_ID Expected=$EXPECTED_TEAM_ID"
  exit 1
fi

if [[ "$CANDIDATE_RELEASE_REPO" != "$EXPECTED_RELEASE_REPO" ]]; then
  echo "ERROR: Candidate release repo mismatch. Found=$CANDIDATE_RELEASE_REPO Expected=$EXPECTED_RELEASE_REPO"
  exit 1
fi

if [[ "$SKIP_CANDIDATE_SIGNATURE" -ne 1 ]]; then
  CANDIDATE_TEAM_ID="$(read_team_id "$CANDIDATE_APP")"
  if [[ "$CANDIDATE_TEAM_ID" != "$EXPECTED_TEAM_ID" ]]; then
    echo "ERROR: Candidate Team ID mismatch. Found=$CANDIDATE_TEAM_ID Expected=$EXPECTED_TEAM_ID"
    exit 1
  fi
fi

if [[ "$(normalize_version "$CANDIDATE_VERSION")" < "$(normalize_version "$INSTALLED_VERSION")" ]]; then
  echo "ERROR: Candidate version $CANDIDATE_VERSION is older than installed version $INSTALLED_VERSION"
  exit 1
fi

echo "Upgrade validation passed"
echo "  installed: $INSTALLED_APP ($INSTALLED_VERSION)"
echo "  candidate: $CANDIDATE_APP ($CANDIDATE_VERSION)"
echo "  bundle id: $EXPECTED_BUNDLE_ID"
echo "  release repo: $EXPECTED_RELEASE_REPO"
