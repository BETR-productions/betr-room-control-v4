#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="$PROJECT_DIR/build"
APP_NAME="BETR Room Control"
APP_EXECUTABLE="RoomControlApp"
APP_BUNDLE_ID="com.betr.room-control"
CORE_AGENT_IDENTIFIER="com.betr.core-agent"
NETWORK_HELPER_IDENTIFIER="com.betr.network-helper"
TEAM_ID="Y8WQ4W4L59"
DEFAULT_DEVELOPER_ID_IDENTITY="Developer ID Application: Joshua Perlman (Y8WQ4W4L59)"
DEFAULT_DEVELOPER_ID_INSTALLER_IDENTITY="Developer ID Installer: Joshua Perlman (Y8WQ4W4L59)"
DEFAULT_VERSION="0.9.8.86"
APP_ICON_SOURCE="$PROJECT_DIR/Resources/AppIcon.png"
ROUND_ICON_SCRIPT="$PROJECT_DIR/scripts/round-icon.swift"
CONFIGURATION="debug"
SIGN_BUNDLE=0
CREATE_ZIP=0
CREATE_DMG=0
CREATE_PKG=0
NOTARIZE_BUNDLE=0
STAPLE_BUNDLE=0
SIGN_IDENTITY="${SIGN_IDENTITY:-${SIGN_ID:-}}"
INSTALLER_SIGN_IDENTITY="${INSTALLER_SIGN_IDENTITY:-${INSTALLER_SIGN_ID:-}}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
VERSION_OVERRIDE="${VERSION_OVERRIDE:-}"
RAW_VERSION_ARGUMENT=""
RELEASE_TRACK_OVERRIDE="${RELEASE_TRACK:-}"
UPDATE_SEQUENCE_OVERRIDE="${UPDATE_SEQUENCE:-}"
BETR_CORE_DIR="${BETR_CORE_DIR:-}"
BETR_NDI_REDIST_DIR="${BETR_NDI_REDIST_DIR:-}"
ROOM_CONTROL_GIT_SHA=""
CORE_GIT_SHA=""
RELEASE_STYLE=0
OBFUSCATED_PAT=""
OBFUSCATION_KEY=""
RELEASE_TRACK_VALUE="legacy"
UPDATE_SEQUENCE_VALUE="0"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --configuration <debug|release>   Swift build configuration. Default: debug
  --version <version>               Bundle/app version. Default: ${DEFAULT_VERSION}
  --core-dir <path>                 Override BETR_CORE_DIR for the embedded BETRCoreAgent build
  --release-style                   Build a release bundle signed with the default Developer ID identity
  --sign                            Code sign the app and helper using SIGN_IDENTITY or SIGN_ID
  --sign-identity <identity>        Override the signing identity to use with --sign
  --release-track <legacy|bridge|date>
                                    Embed updater track metadata. Default: inferred from version
  --update-sequence <sequence>      Override the hidden monotonic updater sequence
  --notarize                        Submit the signed app/DMG for notarization using NOTARY_PROFILE or --notary-profile
  --notary-profile <profile>        Keychain profile name for xcrun notarytool
  --staple                          Staple notarization tickets after successful notarization
  --installer-identity <identity>   Override the Developer ID Installer identity used for PKG signing
  --zip                             Create the updater ZIP after building the app bundle
  --dmg                             Create the DMG after building the app bundle
  --pkg                             Create a signed installer PKG that installs the app and privileged helper
  --skip-zip                        Do not create the updater ZIP
  --skip-dmg                        Do not create the DMG
  --skip-pkg                        Do not create the PKG
  --help                            Show this message
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
  # The `0.9.8.x` bridge line moves legacy installs onto the hidden
  # update-sequence path before visible versions switch to the date-based line.
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
      # Published bridge builds should pass an explicit `--update-sequence`.
      # This deterministic date fallback keeps local builds stable when no
      # explicit sequence is provided.
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

detect_core_dir_from_package() {
  local candidate
  for candidate in \
    "$PROJECT_DIR/../betr-core-v3" \
    "$PROJECT_DIR/../../macos-apps/betr-core-v3"
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

detect_ndi_redist_dir() {
  local candidate
  local candidates=()

  if [[ -n "$BETR_NDI_REDIST_DIR" ]]; then
    candidates+=("$BETR_NDI_REDIST_DIR")
  fi

  candidates+=(
    "$BETR_CORE_DIR/Vendor/NDI/lib/macos"
    "$PROJECT_DIR/../betr-core-v2/Vendor/NDI/lib/macos"
    "$PROJECT_DIR/../../macos-apps/betr-core-v2/Vendor/NDI/lib/macos"
    "/Library/NDI SDK for Apple/lib/macOS"
    "$HOME/Library/NDI SDK for Apple/lib/macOS"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate/libndi.dylib" && -f "$candidate/libndi_advanced.dylib" ]]; then
      (
        cd "$candidate" >/dev/null 2>&1 && pwd
      )
      return 0
    fi
  done

  return 1
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
    echo "Room Control packaging must embed a clean BETRCoreAgent build."
    exit 1
  fi
}

capture_build_shas() {
  if git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    ROOM_CONTROL_GIT_SHA="$(git -C "$PROJECT_DIR" rev-parse HEAD)"
  fi
  CORE_GIT_SHA="$(git -C "$BETR_CORE_DIR" rev-parse HEAD)"
}

write_app_plist() {
  local plist_path="$1"
  local version="$2"
  cat > "$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${APP_BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleVersion</key>
    <string>${version}</string>
    <key>CFBundleShortVersionString</key>
    <string>${version}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.video</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>BETR Room Control uses the local network for NDI discovery, receive, and output.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_ndi._tcp</string>
    </array>
    <key>NSAppleEventsUsageDescription</key>
    <string>BETR Room Control controls PowerPoint and Keynote presentations through AppleScript.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>BETR Room Control captures routed presentation surfaces for operator monitoring and output.</string>
    <key>BETRReleaseRepository</key>
    <string>BETR-productions/betr-room-control-v2</string>
    <key>BETRTeamIdentifier</key>
    <string>${TEAM_ID}</string>
    <key>BETRCoreAgentBundled</key>
    <true/>
    <key>BETRCoreAgentLaunchAgentPlist</key>
    <string>com.betr.core-agent.plist</string>
    <key>BETRRoomControlGitSHA</key>
    <string>${ROOM_CONTROL_GIT_SHA}</string>
    <key>BETRCoreGitSHA</key>
    <string>${CORE_GIT_SHA}</string>
    <key>BETRReleaseTrack</key>
    <string>${RELEASE_TRACK_VALUE}</string>
    <key>BETRUpdateSequence</key>
    <string>${UPDATE_SEQUENCE_VALUE}</string>
    <key>BETRUpdateTokenData</key>
    <string>${OBFUSCATED_PAT}</string>
    <key>BETRUpdateTokenKey</key>
    <string>${OBFUSCATION_KEY}</string>
</dict>
</plist>
PLIST
}

write_bundled_launch_agent_plist() {
  local plist_path="$1"
  cat > "$plist_path" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.betr.core-agent</string>
    <key>BundleProgram</key>
    <string>Contents/Helpers/BETRCoreAgent</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>MachServices</key>
    <dict>
        <key>com.betr.core-agent</key>
        <true/>
    </dict>
    <key>StandardOutPath</key>
    <string>/Users/Shared/BETR/Logs/BETRCoreAgent.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/Shared/BETR/Logs/BETRCoreAgent.log</string>
</dict>
</plist>
PLIST
}

write_installer_postinstall_script() {
  local script_path="$1"
  cat > "$script_path" <<'SCRIPT'
#!/bin/bash
set -euo pipefail

APP_PATH="/Applications/BETR Room Control.app"
HELPER_SOURCE="$APP_PATH/Contents/Helpers/BETRNetworkHelper"
INSTALLED_HELPER="/Library/PrivilegedHelperTools/com.betr.network-helper"
LAUNCH_DAEMON_PLIST="/Library/LaunchDaemons/com.betr.network-helper.plist"
LOG_DIR="/Library/Logs/BETR"

if [[ ! -x "$HELPER_SOURCE" ]]; then
  echo "BETR installer could not find BETRNetworkHelper inside the installed app bundle." >&2
  exit 1
fi

/bin/mkdir -p "/Library/PrivilegedHelperTools"
/bin/mkdir -p "/Library/LaunchDaemons"
/bin/mkdir -p "$LOG_DIR"

/bin/launchctl bootout "system/com.betr.network-helper" >/dev/null 2>&1 || true
/usr/bin/install -o root -g wheel -m 755 "$HELPER_SOURCE" "$INSTALLED_HELPER"
cat > "$LAUNCH_DAEMON_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.betr.network-helper</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Library/PrivilegedHelperTools/com.betr.network-helper</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>MachServices</key>
    <dict>
        <key>com.betr.network-helper</key>
        <true/>
    </dict>
    <key>StandardOutPath</key>
    <string>/Library/Logs/BETR/BETRNetworkHelper.log</string>
    <key>StandardErrorPath</key>
    <string>/Library/Logs/BETR/BETRNetworkHelper.log</string>
</dict>
</plist>
PLIST
/usr/sbin/chown root:wheel "$LAUNCH_DAEMON_PLIST"
/bin/chmod 644 "$LAUNCH_DAEMON_PLIST"
/bin/launchctl bootstrap system "$LAUNCH_DAEMON_PLIST"
/bin/launchctl kickstart -k "system/com.betr.network-helper" >/dev/null 2>&1 || true

exit 0
SCRIPT
  chmod 755 "$script_path"
}

write_build_metadata() {
  local metadata_path="$1"
  cat > "$metadata_path" <<EOF
VERSION="${VERSION}"
ROOM_CONTROL_GIT_SHA="${ROOM_CONTROL_GIT_SHA}"
CORE_GIT_SHA="${CORE_GIT_SHA}"
BETR_CORE_DIR="${BETR_CORE_DIR}"
SIGN_IDENTITY="${SIGN_IDENTITY}"
RELEASE_TRACK="${RELEASE_TRACK_VALUE}"
UPDATE_SEQUENCE="${UPDATE_SEQUENCE_VALUE}"
EOF
}

copy_file_if_present() {
  local source_path="$1"
  local destination_path="$2"
  if [[ -f "$source_path" ]]; then
    cp "$source_path" "$destination_path"
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

copy_ndi_runtime() {
  local destination_dir="$1"
  mkdir -p "$destination_dir"
  cp "$NDI_VENDOR_DIR/libndi.dylib" "$destination_dir/libndi.dylib"
  cp "$NDI_VENDOR_DIR/libndi_advanced.dylib" "$destination_dir/libndi_advanced.dylib"
  chmod 755 "$destination_dir/libndi.dylib" "$destination_dir/libndi_advanced.dylib"
}

sign_path_if_requested() {
  local target_path="$1"
  local entitlements_path="${2:-}"
  local identifier="${3:-}"

  if [[ "$SIGN_BUNDLE" -ne 1 ]]; then
    return 0
  fi

  if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "ERROR: --sign was requested but no SIGN_IDENTITY or SIGN_ID is available."
    exit 1
  fi

  local codesign_args=(--force --sign "$SIGN_IDENTITY" --options runtime --timestamp)
  if [[ -n "$identifier" ]]; then
    codesign_args+=(--identifier "$identifier")
  fi

  if [[ -n "$entitlements_path" ]]; then
    codesign "${codesign_args[@]}" --entitlements "$entitlements_path" "$target_path"
  else
    codesign "${codesign_args[@]}" "$target_path"
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
    --core-dir)
      BETR_CORE_DIR="$2"
      shift 2
      ;;
    --release-style)
      RELEASE_STYLE=1
      CONFIGURATION="release"
      SIGN_BUNDLE=1
      shift
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
    --installer-identity)
      INSTALLER_SIGN_IDENTITY="$2"
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
    --zip)
      CREATE_ZIP=1
      shift
      ;;
    --dmg)
      CREATE_DMG=1
      shift
      ;;
    --pkg)
      CREATE_PKG=1
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
    --skip-pkg)
      CREATE_PKG=0
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

if [[ "$RELEASE_STYLE" -eq 1 && -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$DEFAULT_DEVELOPER_ID_IDENTITY"
fi

if [[ "$RELEASE_STYLE" -eq 1 && -z "$INSTALLER_SIGN_IDENTITY" ]]; then
  INSTALLER_SIGN_IDENTITY="$DEFAULT_DEVELOPER_ID_INSTALLER_IDENTITY"
fi

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

if [[ ! -d "$BETR_CORE_DIR" ]]; then
  BETR_CORE_DIR="$(detect_core_dir_from_package || true)"
fi

if [[ -z "$BETR_CORE_DIR" || ! -d "$BETR_CORE_DIR" ]]; then
  echo "ERROR: Could not locate betr-core-v3. Set BETR_CORE_DIR before packaging."
  exit 1
fi

NDI_VENDOR_DIR="$(detect_ndi_redist_dir || true)"
NDI_VENDOR_LICENSE=""

ensure_clean_core_checkout
capture_build_shas

if [[ -z "$NDI_VENDOR_DIR" || ! -f "$NDI_VENDOR_DIR/libndi.dylib" || ! -f "$NDI_VENDOR_DIR/libndi_advanced.dylib" ]]; then
  echo "ERROR: Could not locate an NDI redistributable folder with libndi.dylib and libndi_advanced.dylib."
  echo "Set BETR_NDI_REDIST_DIR if the active runtime is stored somewhere else."
  exit 1
fi

if [[ "$NOTARIZE_BUNDLE" -eq 1 && "$SIGN_BUNDLE" -ne 1 ]]; then
  echo "ERROR: --notarize requires --sign so the bundle is signed before submission."
  exit 1
fi

if [[ "$CREATE_PKG" -eq 1 && -z "$INSTALLER_SIGN_IDENTITY" ]]; then
  echo "ERROR: --pkg requires a Developer ID Installer identity. Set INSTALLER_SIGN_IDENTITY or use --installer-identity."
  exit 1
fi

if [[ "$NOTARIZE_BUNDLE" -eq 1 && -z "$NOTARY_PROFILE" ]]; then
  echo "ERROR: --notarize requires NOTARY_PROFILE or --notary-profile."
  exit 1
fi

if [[ -f "$NDI_VENDOR_DIR/libndi_licenses.txt" ]]; then
  NDI_VENDOR_LICENSE="$NDI_VENDOR_DIR/libndi_licenses.txt"
fi

echo "== Building ${APP_NAME} =="
echo "Configuration: $CONFIGURATION"
echo "Version: $VERSION"
echo "BETR core dir: $BETR_CORE_DIR"
echo "NDI redistributable dir: $NDI_VENDOR_DIR"
echo "Release track: $RELEASE_TRACK_VALUE"
echo "Update sequence: $UPDATE_SEQUENCE_VALUE"
if [[ "$SIGN_BUNDLE" -eq 1 ]]; then
  echo "Signing identity: $SIGN_IDENTITY"
fi
if [[ "$CREATE_PKG" -eq 1 ]]; then
  echo "Installer identity: $INSTALLER_SIGN_IDENTITY"
fi
echo "Room Control SHA: $ROOM_CONTROL_GIT_SHA"
echo "Core SHA: $CORE_GIT_SHA"

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

export BETR_CORE_DIR
swift build --package-path "$PROJECT_DIR" -c "$CONFIGURATION" --product "$APP_EXECUTABLE"
ROOM_CONTROL_BIN_DIR="$(swift build --package-path "$PROJECT_DIR" -c "$CONFIGURATION" --show-bin-path)"
swift build --package-path "$BETR_CORE_DIR" -c "$CONFIGURATION" --product BETRCoreAgent
swift build --package-path "$BETR_CORE_DIR" -c "$CONFIGURATION" --product BETRNetworkHelper
CORE_BIN_DIR="$(swift build --package-path "$BETR_CORE_DIR" -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP_BUNDLE"
mkdir -p \
  "$CONTENTS_DIR/MacOS" \
  "$CONTENTS_DIR/Helpers" \
  "$CONTENTS_DIR/Resources" \
  "$CONTENTS_DIR/Frameworks" \
  "$CONTENTS_DIR/Library/LaunchAgents"

cp "$ROOM_CONTROL_BIN_DIR/$APP_EXECUTABLE" "$CONTENTS_DIR/MacOS/$APP_NAME"
chmod +x "$CONTENTS_DIR/MacOS/$APP_NAME"

cp "$CORE_BIN_DIR/BETRCoreAgent" "$CONTENTS_DIR/Helpers/BETRCoreAgent"
chmod +x "$CONTENTS_DIR/Helpers/BETRCoreAgent"

cp "$CORE_BIN_DIR/BETRNetworkHelper" "$CONTENTS_DIR/Helpers/BETRNetworkHelper"
chmod +x "$CONTENTS_DIR/Helpers/BETRNetworkHelper"

write_app_plist "$CONTENTS_DIR/Info.plist" "$VERSION"
write_bundled_launch_agent_plist "$CONTENTS_DIR/Library/LaunchAgents/com.betr.core-agent.plist"
echo -n "APPL????" > "$CONTENTS_DIR/PkgInfo"

copy_file_if_present "$NDI_VENDOR_LICENSE" "$CONTENTS_DIR/Resources/NDI-LICENSES.txt"
copy_file_if_present "$APP_ICON_SOURCE" "$CONTENTS_DIR/Resources/AppIcon.png"
copy_ndi_runtime "$CONTENTS_DIR/Frameworks"
generate_app_icon_if_present "$CONTENTS_DIR/Resources"

if command -v xcrun >/dev/null 2>&1; then
  xcrun swift-stdlib-tool \
    --copy \
    --platform macosx \
    --destination "$CONTENTS_DIR/Frameworks" \
    --scan-executable "$CONTENTS_DIR/MacOS/$APP_NAME" \
    --scan-executable "$CONTENTS_DIR/Helpers/BETRCoreAgent" \
    --scan-executable "$CONTENTS_DIR/Helpers/BETRNetworkHelper" \
    >/dev/null 2>&1 || true
fi

write_build_metadata "$ARTIFACT_DIR/build-metadata.env"

if [[ "$SIGN_BUNDLE" -eq 1 ]]; then
  APP_ENTITLEMENTS="$ARTIFACT_DIR/entitlements-app.plist"
  HELPER_ENTITLEMENTS="$ARTIFACT_DIR/entitlements-helper.plist"

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
</dict>
</plist>
PLIST

  cat > "$HELPER_ENTITLEMENTS" <<'PLIST'
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
  sign_path_if_requested "$CONTENTS_DIR/Frameworks/libndi.dylib"
  sign_path_if_requested "$CONTENTS_DIR/Frameworks/libndi_advanced.dylib"
  sign_path_if_requested "$CONTENTS_DIR/Helpers/BETRCoreAgent" "$HELPER_ENTITLEMENTS" "$CORE_AGENT_IDENTIFIER"
  sign_path_if_requested "$CONTENTS_DIR/Helpers/BETRNetworkHelper" "" "$NETWORK_HELPER_IDENTIFIER"
  sign_path_if_requested "$APP_BUNDLE" "$APP_ENTITLEMENTS" "$APP_BUNDLE_ID"
  codesign --verify --deep --strict "$APP_BUNDLE"
fi

ZIP_PATH="$ARTIFACT_DIR/BETR-Room-Control-v${VERSION}.zip"
DMG_PATH="$ARTIFACT_DIR/BETR-Room-Control-v${VERSION}.dmg"
PKG_PATH="$ARTIFACT_DIR/BETR-Room-Control-v${VERSION}.pkg"

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
  cp -R "$APP_BUNDLE" "$DMG_STAGING_DIR/"
  ln -s /Applications "$DMG_STAGING_DIR/Applications"
  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH" \
    >/dev/null
  rm -rf "$DMG_STAGING_DIR"

  if [[ "$NOTARIZE_BUNDLE" -eq 1 ]]; then
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    if [[ "$STAPLE_BUNDLE" -eq 1 ]]; then
      xcrun stapler staple "$DMG_PATH"
    fi
  fi
fi

if [[ "$CREATE_PKG" -eq 1 ]]; then
  rm -f "$PKG_PATH"
  PKG_STAGING_DIR="$(mktemp -d)"
  PKG_ROOT="$PKG_STAGING_DIR/root"
  PKG_SCRIPTS_DIR="$PKG_STAGING_DIR/scripts"
  mkdir -p "$PKG_ROOT/Applications" "$PKG_SCRIPTS_DIR"
  ditto "$APP_BUNDLE" "$PKG_ROOT/Applications/${APP_NAME}.app"
  write_installer_postinstall_script "$PKG_SCRIPTS_DIR/postinstall"

  pkgbuild \
    --root "$PKG_ROOT" \
    --scripts "$PKG_SCRIPTS_DIR" \
    --identifier "${APP_BUNDLE_ID}.installer" \
    --version "$VERSION" \
    --install-location "/" \
    --sign "$INSTALLER_SIGN_IDENTITY" \
    "$PKG_PATH" \
    >/dev/null

  rm -rf "$PKG_STAGING_DIR"

  if [[ "$NOTARIZE_BUNDLE" -eq 1 ]]; then
    xcrun notarytool submit "$PKG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    if [[ "$STAPLE_BUNDLE" -eq 1 ]]; then
      xcrun stapler staple "$PKG_PATH"
    fi
  fi
fi

echo ""
echo "App bundle: $APP_BUNDLE"
echo "Embedded BETRCoreAgent: $CONTENTS_DIR/Helpers/BETRCoreAgent"
echo "Embedded BETRNetworkHelper: $CONTENTS_DIR/Helpers/BETRNetworkHelper"
echo "Embedded LaunchAgent plist: $CONTENTS_DIR/Library/LaunchAgents/com.betr.core-agent.plist"
echo "Embedded NDI runtime:"
echo "  - $CONTENTS_DIR/Frameworks/libndi.dylib"
echo "  - $CONTENTS_DIR/Frameworks/libndi_advanced.dylib"
if [[ "$CREATE_ZIP" -eq 1 ]]; then
  echo "Updater ZIP: $ZIP_PATH"
fi
if [[ "$CREATE_DMG" -eq 1 ]]; then
  echo "DMG: $DMG_PATH"
fi
if [[ "$CREATE_PKG" -eq 1 ]]; then
  echo "Installer PKG: $PKG_PATH"
fi
if [[ "$NOTARIZE_BUNDLE" -eq 1 ]]; then
  echo "Notarization: submitted with profile $NOTARY_PROFILE"
fi
