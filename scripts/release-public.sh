#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACT_DIR="$PROJECT_DIR/build/artifacts/release"
RELEASE_REPO="${RELEASE_REPO:-BETR-productions/betr-room-control-v2}"
DEFAULT_INSTALLER_IDENTITY="${INSTALLER_SIGN_IDENTITY:-${INSTALLER_IDENTITY:-Developer ID Installer: Joshua Perlman (Y8WQ4W4L59)}}"
RELEASE_NOTES=""
BUILD_ARGS=()
PKG_MODE="auto"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes)
      RELEASE_NOTES="$2"
      shift 2
      ;;
    --sign|--notarize|--staple|--skip-zip|--skip-dmg)
      BUILD_ARGS+=("$1")
      shift
      ;;
    --skip-pkg)
      PKG_MODE="skip"
      shift
      ;;
    --pkg)
      PKG_MODE="include"
      BUILD_ARGS+=("$1")
      shift
      ;;
    --sign-identity|--installer-identity|--notary-profile|--configuration|--version|--core-dir|--release-track|--update-sequence)
      BUILD_ARGS+=("$1" "$2")
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
done

echo "== BETR Room Control v4 public release =="
echo "Public feed: $RELEASE_REPO"

BUILD_COMMAND=("$PROJECT_DIR/scripts/build-app.sh" --release-style --zip --dmg)
if [[ "$PKG_MODE" == "include" ]]; then
  BUILD_COMMAND+=(--pkg)
elif [[ "$PKG_MODE" == "auto" ]]; then
  if security find-identity -v -p basic | grep -Fq "$DEFAULT_INSTALLER_IDENTITY"; then
    BUILD_COMMAND+=(--pkg)
  else
    echo "Skipping installer PKG: $DEFAULT_INSTALLER_IDENTITY is not available in Keychain."
  fi
fi
if (( ${#BUILD_ARGS[@]} > 0 )); then
  BUILD_COMMAND+=("${BUILD_ARGS[@]}")
fi

"${BUILD_COMMAND[@]}"

APP_BUNDLE="$ARTIFACT_DIR/BETR Room Control.app"
VERSION="$(defaults read "$APP_BUNDLE/Contents/Info" CFBundleShortVersionString)"
TAG="v${VERSION}"
ZIP_PATH="$ARTIFACT_DIR/BETR-Room-Control-v${VERSION}.zip"
DMG_PATH="$ARTIFACT_DIR/BETR-Room-Control-v${VERSION}.dmg"
PKG_PATH="$ARTIFACT_DIR/BETR-Room-Control-v${VERSION}.pkg"
BUILD_METADATA="$ARTIFACT_DIR/build-metadata.env"

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "ERROR: App bundle missing: $APP_BUNDLE"
  exit 1
fi
if [[ ! -f "$ZIP_PATH" ]]; then
  echo "ERROR: Updater ZIP missing: $ZIP_PATH"
  exit 1
fi
if [[ ! -f "$DMG_PATH" ]]; then
  echo "ERROR: DMG missing: $DMG_PATH"
  exit 1
fi
if [[ ! -f "$BUILD_METADATA" ]]; then
  echo "ERROR: Build metadata missing: $BUILD_METADATA"
  exit 1
fi

source "$BUILD_METADATA"

"$PROJECT_DIR/scripts/validate-packaged-agent.sh" --configuration release --expected-mode embeddedSMAppService
"$PROJECT_DIR/scripts/validate-upgrade.sh" --candidate "$APP_BUNDLE"

if [[ -z "$RELEASE_NOTES" ]]; then
  RELEASE_NOTES=$'BETR Room Control '"${VERSION}"$'\n\nBETR-Release-Track: '"${RELEASE_TRACK}"$'\nBETR-Update-Sequence: '"${UPDATE_SEQUENCE}"$'\n\nRoom Control SHA: '"${ROOM_CONTROL_GIT_SHA}"$'\nCore SHA: '"${CORE_GIT_SHA}"
else
  RELEASE_NOTES="${RELEASE_NOTES}"$'\n\nBETR-Release-Track: '"${RELEASE_TRACK}"$'\nBETR-Update-Sequence: '"${UPDATE_SEQUENCE}"$'\n\nRoom Control SHA: '"${ROOM_CONTROL_GIT_SHA}"$'\nCore SHA: '"${CORE_GIT_SHA}"
fi

if gh release view "$TAG" -R "$RELEASE_REPO" >/dev/null 2>&1; then
  gh release edit "$TAG" \
    -R "$RELEASE_REPO" \
    --title "$TAG" \
    --notes "$RELEASE_NOTES"
  if [[ -f "$PKG_PATH" ]]; then
    gh release upload "$TAG" "$DMG_PATH" "$ZIP_PATH" "$PKG_PATH" -R "$RELEASE_REPO" --clobber
  else
    gh release upload "$TAG" "$DMG_PATH" "$ZIP_PATH" -R "$RELEASE_REPO" --clobber
  fi
else
  if [[ -f "$PKG_PATH" ]]; then
    gh release create "$TAG" "$DMG_PATH" "$ZIP_PATH" "$PKG_PATH" \
      -R "$RELEASE_REPO" \
      --title "$TAG" \
      --notes "$RELEASE_NOTES"
  else
    gh release create "$TAG" "$DMG_PATH" "$ZIP_PATH" \
      -R "$RELEASE_REPO" \
      --title "$TAG" \
      --notes "$RELEASE_NOTES"
  fi
fi

echo ""
echo "Published $TAG to https://github.com/$RELEASE_REPO/releases/tag/$TAG"
