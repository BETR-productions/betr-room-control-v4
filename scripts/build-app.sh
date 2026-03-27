#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="$PROJECT_DIR/build"
APP_DISPLAY_NAME="BËTR Room Control"
APP_NAME="BETR Room Control"
APP_EXECUTABLE="RoomControlApp"
APP_BUNDLE_ID="com.betr.room-control"
TEAM_ID="Y8WQ4W4L59"
DEFAULT_VERSION="0.9.8.71"
CONFIGURATION="release"
SIGN_BUNDLE=0
CREATE_ZIP=1
CREATE_DMG=1
NOTARIZE_BUNDLE=0
STAPLE_BUNDLE=0
SIGN_IDENTITY="${SIGN_IDENTITY:-${SIGN_ID:-}}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
VERSION_OVERRIDE="${VERSION_OVERRIDE:-}"
RAW_VERSION_ARGUMENT=""
RELEASE_TRACK_OVERRIDE="${RELEASE_TRACK:-}"
UPDATE_SEQUENCE_OVERRIDE="${UPDATE_SEQUENCE:-}"
BETR_CORE_DIR="${BETR_CORE_DIR:-}"
ROOM_CONTROL_GIT_SHA=""
CORE_GIT_SHA=""
APP_ICON_PNG="$PROJECT_DIR/Resources/AppIcon.png"
APP_ICON_ICNS="$PROJECT_DIR/Resources/AppIcon.icns"
ROUND_ICON_SCRIPT="$PROJECT_DIR/scripts/round-icon.swift"
DMG_BG_SOURCE="$PROJECT_DIR/Resources/DMGBackground.png"
DMG_BG_GEN_SCRIPT="$PROJECT_DIR/scripts/generate-dmg-background.swift"
OBFUSCATED_PAT=""
OBFUSCATION_KEY=""
RELEASE_TRACK_VALUE="legacy"
UPDATE_SEQUENCE_VALUE="0"

# XPC services built from betr-room-control-v4 Package.swift.
# In v4, domain modules (ClipPlayerDomain, TimerDomain, PresentationDomain) are
# library targets linked into RoomControlApp — not separate XPC executables.
# Add entries here if future Package.swift targets introduce XPC executables.
# Format: "ExecutableName:com.bundle.id"
XPC_SERVICES=()

# BETRCoreAgent is built from betr-core-v3 and embedded as a helper
CORE_AGENT_NAME="BETRCoreAgent"
CORE_AGENT_BUNDLE_ID="com.betr.room-control-v4.BETRCoreAgent"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --configuration <debug|release>   Swift build configuration. Default: release
  --version <version>               Bundle/app version. Default: $DEFAULT_VERSION
  --release-track <legacy|bridge|date>
                                    Embed updater track metadata. Default: inferred from version
  --update-sequence <sequence>      Override the hidden monotonic updater sequence
  --sign                            Code sign the app and XPC bundles using SIGN_IDENTITY or SIGN_ID
  --sign-identity <identity>        Override the signing identity to use with --sign
  --notarize                        Submit the signed app/DMG for notarization using NOTARY_PROFILE or --notary-profile
  --notary-profile <profile>        Keychain profile name for xcrun notarytool
  --staple                          Staple notarization tickets after successful notarization
  --skip-zip                        Do not create the updater ZIP
  --skip-dmg                        Do not create the DMG
  --help                            Show this message

Environment:
  BETR_CORE_DIR   Path to betr-core-v3 checkout (default: sibling of this repo)
  SIGN_IDENTITY   Signing identity (alternative to --sign-identity)
  SIGN_ID         Alias for SIGN_IDENTITY
  NOTARY_PROFILE  Notarytool Keychain profile (alternative to --notary-profile)
EOF
}

canonicalize_version() {
  local raw="$1"
  if [[ "$raw" == .* ]]; then
    echo "0${raw}"
  else
    echo "$raw"
  fi
}

infer_release_track() {
  local version_argument="$1"
  local canonical_version="$2"
  local explicit_track="$3"
  if [[ -n "$explicit_track" ]]; then
    echo "$explicit_track"
    return 0
  fi
  if [[ "$canonical_version" =~ ^0\.9\.8\.[0-9]+$ ]]; then
    echo "bridge"
    return 0
  fi
  if [[ "$version_argument" == .* ]]; then
    echo "date"
    return 0
  fi
  echo "legacy"
}

default_update_sequence() {
  local canonical_version="$1"
  local release_track="$2"
  local year
  local month
  local day
  local build
  year="$(date +%Y)"

  case "$release_track" in
    bridge)
      printf "%04d%02d%02d%02d\n" "$year" "$(date +%-m)" "$(date +%-d)" 2
      ;;
    date)
      IFS='.' read -r _ month day build <<< "$canonical_version"
      printf "%04d%02d%02d%02d\n" "$year" "${month:-0}" "${day:-0}" "${build:-1}"
      ;;
    *)
      echo "0"
      ;;
  esac
}

contains_item() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

detect_core_dir_from_package() {
  local candidate
  for candidate in \
    "$PROJECT_DIR/../betr-core-v3" \
    "$PROJECT_DIR/../../betr-core-v3"
  do
    if [[ -d "$candidate" ]]; then
      (
        cd "$candidate" >/dev/null 2>&1 && pwd
      )
      return 0
    fi
  done
  return 1
}

write_app_plist() {
  local plist_path="$1"
  local short_version="$2"
  local build_version="${short_version}.0"
  cat > "$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_DISPLAY_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${APP_BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>${build_version}</string>
    <key>CFBundleShortVersionString</key>
    <string>${short_version}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.video</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>BËTR Room Control uses the local network for NDI discovery, receive, and output.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_ndi._tcp</string>
    </array>
    <key>NSAppleEventsUsageDescription</key>
    <string>BËTR Room Control controls PowerPoint and Keynote presentations through AppleScript.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>BËTR Room Control captures routed presentation surfaces for operator monitoring and output.</string>
    <key>BETRReleaseRepository</key>
    <string>BETR-productions/betr-room-control-v2</string>
    <key>BETRTeamIdentifier</key>
    <string>${TEAM_ID}</string>
    <key>BETRReleaseTrack</key>
    <string>${RELEASE_TRACK_VALUE}</string>
    <key>BETRUpdateSequence</key>
    <string>${UPDATE_SEQUENCE_VALUE}</string>
    <key>BETRRoomControlGitSHA</key>
    <string>${ROOM_CONTROL_GIT_SHA}</string>
    <key>BETRCoreGitSHA</key>
    <string>${CORE_GIT_SHA}</string>
    <key>BETRUpdateTokenData</key>
    <string>${OBFUSCATED_PAT}</string>
    <key>BETRUpdateTokenKey</key>
    <string>${OBFUSCATION_KEY}</string>
</dict>
</plist>
PLIST
}

ensure_clean_core_checkout() {
  if ! git -C "$BETR_CORE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: BETR_CORE_DIR '$BETR_CORE_DIR' is not a git checkout."
    exit 1
  fi

  local dirty
  dirty="$(git -C "$BETR_CORE_DIR" status --porcelain)"
  if [[ -n "$dirty" ]]; then
    echo "ERROR: Core checkout '$BETR_CORE_DIR' has uncommitted changes."
    echo "Builds for Room Control releases must package against a clean Core checkout."
    exit 1
  fi
}

capture_build_shas() {
  if git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    ROOM_CONTROL_GIT_SHA="$(git -C "$PROJECT_DIR" rev-parse HEAD)"
  fi
  CORE_GIT_SHA="$(git -C "$BETR_CORE_DIR" rev-parse HEAD)"
}

write_build_metadata() {
  local metadata_path="$1"
  cat > "$metadata_path" <<EOF
VERSION="${VERSION}"
ROOM_CONTROL_GIT_SHA="${ROOM_CONTROL_GIT_SHA}"
CORE_GIT_SHA="${CORE_GIT_SHA}"
BETR_CORE_DIR="${BETR_CORE_DIR}"
RELEASE_TRACK="${RELEASE_TRACK_VALUE}"
UPDATE_SEQUENCE="${UPDATE_SEQUENCE_VALUE}"
EOF
}

write_xpc_plist() {
  local plist_path="$1"
  local bundle_id="$2"
  local executable="$3"
  local version="$4"
  cat > "$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${bundle_id}</string>
    <key>CFBundleName</key>
    <string>${executable}</string>
    <key>CFBundleExecutable</key>
    <string>${executable}</string>
    <key>CFBundleVersion</key>
    <string>${version}.0</string>
    <key>CFBundleShortVersionString</key>
    <string>${version}</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>XPCService</key>
    <dict>
        <key>ServiceType</key>
        <string>Application</string>
    </dict>
</dict>
</plist>
PLIST
}

write_agent_plist() {
  local plist_path="$1"
  local bundle_id="$2"
  local executable="$3"
  local version="$4"
  cat > "$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${bundle_id}</string>
    <key>CFBundleName</key>
    <string>${executable}</string>
    <key>CFBundleExecutable</key>
    <string>${executable}</string>
    <key>CFBundleVersion</key>
    <string>${version}.0</string>
    <key>CFBundleShortVersionString</key>
    <string>${version}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>SMPrivilegedExecutables</key>
    <dict/>
</dict>
</plist>
PLIST
}

copy_file_if_present() {
  local source_path="$1"
  local destination_path="$2"
  if [[ -f "$source_path" ]]; then
    cp "$source_path" "$destination_path"
  fi
}

copy_ndi_runtime() {
  local destination_dir="$1"
  local ndi_dir="$BETR_CORE_DIR/Vendor/NDI/lib/macos"
  mkdir -p "$destination_dir"
  cp "$ndi_dir/libndi.dylib" "$destination_dir/libndi.dylib"
  chmod 755 "$destination_dir/libndi.dylib"
  if [[ -f "$ndi_dir/libndi_advanced.dylib" ]]; then
    cp "$ndi_dir/libndi_advanced.dylib" "$destination_dir/libndi_advanced.dylib"
    chmod 755 "$destination_dir/libndi_advanced.dylib"
  fi
}

generate_dmg_background_if_needed() {
  local resources_dir="$1"
  if [[ -f "$resources_dir/DMGBackground.png" ]]; then
    return 0
  fi
  if [[ -f "$DMG_BG_SOURCE" ]]; then
    cp "$DMG_BG_SOURCE" "$resources_dir/DMGBackground.png"
    return 0
  fi
  if [[ -f "$DMG_BG_GEN_SCRIPT" ]]; then
    swift "$DMG_BG_GEN_SCRIPT" "$resources_dir/DMGBackground.png" >/dev/null 2>&1 || true
  fi
}

generate_app_icon_if_present() {
  local resources_dir="$1"
  local icon_png="$resources_dir/AppIcon.png"
  local rounded_icon=""
  local icon_source="$icon_png"
  local iconset_dir=""

  if [[ ! -f "$icon_png" ]]; then
    return 0
  fi

  if [[ -f "$ROUND_ICON_SCRIPT" ]]; then
    rounded_icon="$(mktemp).png"
    if swift "$ROUND_ICON_SCRIPT" "$icon_png" "$rounded_icon" >/dev/null 2>&1 && [[ -s "$rounded_icon" ]]; then
      icon_source="$rounded_icon"
    fi
  fi

  iconset_dir="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$iconset_dir"
  sips -z 16 16     "$icon_source" --out "$iconset_dir/icon_16x16.png"      >/dev/null 2>&1
  sips -z 32 32     "$icon_source" --out "$iconset_dir/icon_16x16@2x.png"   >/dev/null 2>&1
  sips -z 32 32     "$icon_source" --out "$iconset_dir/icon_32x32.png"      >/dev/null 2>&1
  sips -z 64 64     "$icon_source" --out "$iconset_dir/icon_32x32@2x.png"   >/dev/null 2>&1
  sips -z 128 128   "$icon_source" --out "$iconset_dir/icon_128x128.png"    >/dev/null 2>&1
  sips -z 256 256   "$icon_source" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null 2>&1
  sips -z 256 256   "$icon_source" --out "$iconset_dir/icon_256x256.png"    >/dev/null 2>&1
  sips -z 512 512   "$icon_source" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null 2>&1
  sips -z 512 512   "$icon_source" --out "$iconset_dir/icon_512x512.png"    >/dev/null 2>&1
  sips -z 1024 1024 "$icon_source" --out "$iconset_dir/icon_512x512@2x.png" >/dev/null 2>&1
  iconutil -c icns "$iconset_dir" -o "$resources_dir/AppIcon.icns"

  rm -rf "$(dirname "$iconset_dir")"
  if [[ -n "$rounded_icon" ]]; then
    rm -f "$rounded_icon"
  fi
}

sign_path_if_requested() {
  local target_path="$1"
  local entitlements_path="${2:-}"

  if [[ "$SIGN_BUNDLE" -ne 1 ]]; then
    return 0
  fi

  if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "ERROR: --sign was requested but no SIGN_IDENTITY or SIGN_ID is available."
    exit 1
  fi

  if [[ -n "$entitlements_path" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --entitlements "$entitlements_path" "$target_path"
  else
    codesign --force --sign "$SIGN_IDENTITY" --options runtime "$target_path"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration)
      CONFIGURATION="$2"
      shift 2
      ;;
    --version)
      RAW_VERSION_ARGUMENT="$2"
      VERSION_OVERRIDE="$2"
      shift 2
      ;;
    --release-track)
      RELEASE_TRACK_OVERRIDE="$2"
      shift 2
      ;;
    --update-sequence)
      UPDATE_SEQUENCE_OVERRIDE="$2"
      shift 2
      ;;
    --sign)
      SIGN_BUNDLE=1
      shift
      ;;
    --sign-identity)
      SIGN_BUNDLE=1
      SIGN_IDENTITY="$2"
      shift 2
      ;;
    --notarize)
      NOTARIZE_BUNDLE=1
      STAPLE_BUNDLE=1
      shift
      ;;
    --notary-profile)
      NOTARIZE_BUNDLE=1
      STAPLE_BUNDLE=1
      NOTARY_PROFILE="$2"
      shift 2
      ;;
    --staple)
      STAPLE_BUNDLE=1
      shift
      ;;
    --skip-zip)
      CREATE_ZIP=0
      shift
      ;;
    --skip-dmg)
      CREATE_DMG=0
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

case "$CONFIGURATION" in
  debug|release)
    ;;
  *)
    echo "ERROR: Invalid configuration '$CONFIGURATION'. Use 'debug' or 'release'."
    exit 1
    ;;
esac

VERSION="$(canonicalize_version "${VERSION_OVERRIDE:-$DEFAULT_VERSION}")"
RELEASE_TRACK_VALUE="$(infer_release_track "$RAW_VERSION_ARGUMENT" "$VERSION" "$RELEASE_TRACK_OVERRIDE")"
UPDATE_SEQUENCE_VALUE="${UPDATE_SEQUENCE_OVERRIDE:-$(default_update_sequence "$VERSION" "$RELEASE_TRACK_VALUE")}"
ARTIFACT_DIR="$BUILD_ROOT/artifacts/$CONFIGURATION"
APP_BUNDLE="$ARTIFACT_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
BIN_DIR=""
CORE_BIN_DIR=""

if [[ ! -d "$BETR_CORE_DIR" ]]; then
  BETR_CORE_DIR="$(detect_core_dir_from_package || true)"
fi

if [[ -z "$BETR_CORE_DIR" || ! -d "$BETR_CORE_DIR" ]]; then
  echo "ERROR: Could not locate betr-core-v3. Set BETR_CORE_DIR."
  exit 1
fi

NDI_VENDOR_DIR="$BETR_CORE_DIR/Vendor/NDI/lib/macos"

ensure_clean_core_checkout
capture_build_shas

if [[ ! -f "$NDI_VENDOR_DIR/libndi.dylib" ]]; then
  echo "ERROR: libndi.dylib not found in '$NDI_VENDOR_DIR'."
  echo "Set BETR_CORE_DIR if the active Core v3 worktree lives somewhere else."
  exit 1
fi

if [[ "$NOTARIZE_BUNDLE" -eq 1 && "$SIGN_BUNDLE" -ne 1 ]]; then
  echo "ERROR: --notarize requires --sign so the bundle is signed before submission."
  exit 1
fi

if [[ "$NOTARIZE_BUNDLE" -eq 1 && -z "$NOTARY_PROFILE" ]]; then
  echo "ERROR: --notarize requires NOTARY_PROFILE or --notary-profile."
  exit 1
fi

echo "== Building ${APP_DISPLAY_NAME} =="
echo "Configuration: $CONFIGURATION"
echo "Version: $VERSION"
echo "Release track: $RELEASE_TRACK_VALUE"
echo "Update sequence: $UPDATE_SEQUENCE_VALUE"
echo "Core: $BETR_CORE_DIR"
echo "Room Control SHA: $ROOM_CONTROL_GIT_SHA"
echo "Core SHA: $CORE_GIT_SHA"

# Load GitHub PAT and XOR-obfuscate for embedded updater
GITHUB_PAT="$(security find-generic-password -a "betr-room-control" -s "betr-room-control-github-pat" -w 2>/dev/null || true)"
if [[ -z "$GITHUB_PAT" ]]; then
  GITHUB_PAT="${GITHUB_TOKEN:-}"
fi
if [[ -n "$GITHUB_PAT" ]]; then
  PAT_LEN=${#GITHUB_PAT}
  OBFUSCATION_KEY="$(openssl rand -hex "$PAT_LEN")"
  OBFUSCATED_PAT=""
  for (( i=0; i<PAT_LEN; i++ )); do
    PAT_BYTE="$(printf '%02x' "'${GITHUB_PAT:$i:1}")"
    KEY_BYTE="${OBFUSCATION_KEY:$((i * 2)):2}"
    XOR_BYTE="$(printf '%02x' $(( 0x${PAT_BYTE} ^ 0x${KEY_BYTE} )))"
    OBFUSCATED_PAT="${OBFUSCATED_PAT}${XOR_BYTE}"
  done
  echo "GitHub PAT: loaded for embedded updater auth"
else
  echo "GitHub PAT: not found in Keychain or environment; shipped updater checks may be rate-limited"
fi

# Build app from betr-room-control-v4
echo "Building betr-room-control-v4..."
swift build --package-path "$PROJECT_DIR" -c "$CONFIGURATION"
BIN_DIR="$(swift build --package-path "$PROJECT_DIR" -c "$CONFIGURATION" --show-bin-path)"

# Build BETRCoreAgent from betr-core-v3
echo "Building BETRCoreAgent from betr-core-v3..."
swift build --package-path "$BETR_CORE_DIR" -c "$CONFIGURATION" --product "$CORE_AGENT_NAME"
CORE_BIN_DIR="$(swift build --package-path "$BETR_CORE_DIR" -c "$CONFIGURATION" --show-bin-path)"

# Assemble app bundle
rm -rf "$APP_BUNDLE"
mkdir -p \
  "$CONTENTS_DIR/MacOS" \
  "$CONTENTS_DIR/Resources" \
  "$CONTENTS_DIR/Frameworks" \
  "$CONTENTS_DIR/XPCServices" \
  "$CONTENTS_DIR/Library/LaunchAgents"

cp "$BIN_DIR/$APP_EXECUTABLE" "$CONTENTS_DIR/MacOS/$APP_NAME"
chmod +x "$CONTENTS_DIR/MacOS/$APP_NAME"

write_app_plist "$CONTENTS_DIR/Info.plist" "$VERSION"
echo -n "APPL????" > "$CONTENTS_DIR/PkgInfo"

# Prefer pre-built .icns from Resources/ (copied from v3); fall back to PNG generation
if [[ -f "$APP_ICON_ICNS" ]]; then
  cp "$APP_ICON_ICNS" "$CONTENTS_DIR/Resources/AppIcon.icns"
  echo "AppIcon: using pre-built .icns from Resources/"
else
  copy_file_if_present "$APP_ICON_PNG" "$CONTENTS_DIR/Resources/AppIcon.png"
  generate_app_icon_if_present "$CONTENTS_DIR/Resources"
fi

generate_dmg_background_if_needed "$CONTENTS_DIR/Resources"

# Embed BETRCoreAgent (the NDI/core XPC helper from betr-core-v3)
AGENT_BUNDLE="$CONTENTS_DIR/Library/LaunchAgents/${CORE_AGENT_BUNDLE_ID}.app"
AGENT_CONTENTS="$AGENT_BUNDLE/Contents"
mkdir -p "$AGENT_CONTENTS/MacOS" "$AGENT_CONTENTS/Frameworks"
cp "$CORE_BIN_DIR/$CORE_AGENT_NAME" "$AGENT_CONTENTS/MacOS/$CORE_AGENT_NAME"
chmod +x "$AGENT_CONTENTS/MacOS/$CORE_AGENT_NAME"
write_agent_plist "$AGENT_CONTENTS/Info.plist" "$CORE_AGENT_BUNDLE_ID" "$CORE_AGENT_NAME" "$VERSION"
copy_ndi_runtime "$AGENT_CONTENTS/Frameworks"

# Embed app-level XPC services (from betr-room-control-v4 Package.swift)
service_entry=""
for service_entry in ${XPC_SERVICES[@]+${XPC_SERVICES[@]+"${XPC_SERVICES[@]}"}}; do
  service_name="${service_entry%%:*}"
  service_bundle_id="${service_entry#*:}"
  service_bin="$BIN_DIR/$service_name"

  if [[ ! -f "$service_bin" ]]; then
    echo "WARNING: XPC executable not found: $service_bin (may not be defined yet in Package.swift)"
    continue
  fi

  service_bundle="$CONTENTS_DIR/XPCServices/${service_bundle_id}.xpc"
  service_contents="$service_bundle/Contents"

  mkdir -p "$service_contents/MacOS"
  cp "$service_bin" "$service_contents/MacOS/$service_name"
  chmod +x "$service_contents/MacOS/$service_name"
  write_xpc_plist "$service_contents/Info.plist" "$service_bundle_id" "$service_name" "$VERSION"
done

# Copy Swift stdlib into Frameworks
if command -v xcrun >/dev/null 2>&1; then
  SCAN_EXECUTABLES=("$CONTENTS_DIR/MacOS/$APP_NAME" "$AGENT_CONTENTS/MacOS/$CORE_AGENT_NAME")
  for service_entry in ${XPC_SERVICES[@]+${XPC_SERVICES[@]+"${XPC_SERVICES[@]}"}}; do
    service_name="${service_entry%%:*}"
    service_bundle_id="${service_entry#*:}"
    xpc_exec="$CONTENTS_DIR/XPCServices/${service_bundle_id}.xpc/Contents/MacOS/$service_name"
    if [[ -f "$xpc_exec" ]]; then
      SCAN_EXECUTABLES+=("$xpc_exec")
    fi
  done
  xcrun swift-stdlib-tool \
    --copy \
    --platform macosx \
    --destination "$CONTENTS_DIR/Frameworks" \
    $(for exe in "${SCAN_EXECUTABLES[@]}"; do printf -- '--scan-executable %q ' "$exe"; done) \
    >/dev/null 2>&1 || true
fi

write_build_metadata "$ARTIFACT_DIR/build-metadata.env"

# Code signing (inside-out: NDI dylibs → BETRCoreAgent → XPC services → app)
if [[ "$SIGN_BUNDLE" -eq 1 ]]; then
  APP_ENTITLEMENTS="$ARTIFACT_DIR/entitlements-app.plist"
  AGENT_ENTITLEMENTS="$ARTIFACT_DIR/entitlements-agent.plist"
  XPC_ENTITLEMENTS="$ARTIFACT_DIR/entitlements-xpc.plist"

  mkdir -p "$ARTIFACT_DIR"
  cat > "$APP_ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
PLIST

  cat > "$AGENT_ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
PLIST

  cat > "$XPC_ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
PLIST

  xattr -cr "$APP_BUNDLE"

  # 1. Sign NDI dylibs first (deepest leaves)
  sign_path_if_requested "$AGENT_CONTENTS/Frameworks/libndi.dylib"
  sign_path_if_requested "$AGENT_CONTENTS/Frameworks/libndi_advanced.dylib"
  sign_path_if_requested "$CONTENTS_DIR/Frameworks/libndi.dylib" 2>/dev/null || true
  sign_path_if_requested "$CONTENTS_DIR/Frameworks/libndi_advanced.dylib" 2>/dev/null || true

  # 2. Sign BETRCoreAgent
  sign_path_if_requested "$AGENT_BUNDLE" "$AGENT_ENTITLEMENTS"

  # 3. Sign XPC services
  for service_entry in ${XPC_SERVICES[@]+"${XPC_SERVICES[@]}"}; do
    service_name="${service_entry%%:*}"
    service_bundle_id="${service_entry#*:}"
    service_bundle="$CONTENTS_DIR/XPCServices/${service_bundle_id}.xpc"
    if [[ -d "$service_bundle" ]]; then
      sign_path_if_requested "$service_bundle" "$XPC_ENTITLEMENTS"
    fi
  done

  # 4. Sign main app bundle (outermost)
  sign_path_if_requested "$APP_BUNDLE" "$APP_ENTITLEMENTS"
  codesign --verify --deep --strict "$APP_BUNDLE"
fi

ZIP_PATH="$ARTIFACT_DIR/BETR-Room-Control-v${VERSION}.zip"
DMG_PATH="$ARTIFACT_DIR/BETR-Room-Control-v${VERSION}.dmg"

if [[ "$NOTARIZE_BUNDLE" -eq 1 ]]; then
  NOTARY_SUBMISSION_ZIP="$ARTIFACT_DIR/BETR-Room-Control-v${VERSION}-notary.zip"
  rm -f "$NOTARY_SUBMISSION_ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$NOTARY_SUBMISSION_ZIP"
  xcrun notarytool submit "$NOTARY_SUBMISSION_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  if [[ "$STAPLE_BUNDLE" -eq 1 ]]; then
    xcrun stapler staple "$APP_BUNDLE"
  fi
fi

if [[ "$CREATE_ZIP" -eq 1 ]]; then
  rm -f "$ZIP_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
fi

if [[ "$CREATE_DMG" -eq 1 ]]; then
  rm -f "$DMG_PATH"
  DMG_STAGING_DIR="$(mktemp -d)"
  DMG_SCRATCH_DIR="$(mktemp -d)"
  cp -R "$APP_BUNDLE" "$DMG_STAGING_DIR/"
  ln -s /Applications "$DMG_STAGING_DIR/Applications"

  # Create a writable DMG for styling, then convert to compressed final
  DMG_WORK="$DMG_SCRATCH_DIR/work.dmg"
  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING_DIR" \
    -ov \
    -format UDRW \
    -size 300m \
    "$DMG_WORK" \
    >/dev/null

  DMG_MOUNT_DIR="$(mktemp -d)"
  hdiutil attach "$DMG_WORK" -mountpoint "$DMG_MOUNT_DIR" -nobrowse -quiet

  # Set background image if available
  if [[ -f "$DMG_BG_SOURCE" ]]; then
    mkdir -p "$DMG_MOUNT_DIR/.background"
    cp "$DMG_BG_SOURCE" "$DMG_MOUNT_DIR/.background/DMGBackground.png"

    osascript <<ASCRIPT >/dev/null 2>&1 || true
tell application "Finder"
  tell disk "$APP_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {100, 100, 700, 500}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set background picture of viewOptions to file ".background:DMGBackground.png"
    set position of item "$APP_NAME.app" of container window to {160, 200}
    set position of item "Applications" of container window to {440, 200}
    close
    open
    update without registering applications
    delay 2
  end tell
end tell
ASCRIPT
  fi

  hdiutil detach "$DMG_MOUNT_DIR" -quiet
  hdiutil convert "$DMG_WORK" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
  rm -rf "$DMG_STAGING_DIR" "$DMG_SCRATCH_DIR" "$DMG_MOUNT_DIR"

  if [[ "$NOTARIZE_BUNDLE" -eq 1 ]]; then
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    if [[ "$STAPLE_BUNDLE" -eq 1 ]]; then
      xcrun stapler staple "$DMG_PATH"
    fi
  fi
fi

echo ""
echo "App bundle: $APP_BUNDLE"
[[ "$CREATE_ZIP" -eq 1 ]] && echo "Updater ZIP: $ZIP_PATH"
[[ "$CREATE_DMG" -eq 1 ]] && echo "DMG: $DMG_PATH"
if [[ "$NOTARIZE_BUNDLE" -eq 1 ]]; then
  echo "Notarization: submitted with profile $NOTARY_PROFILE"
fi
