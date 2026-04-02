#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="debug"
APP_NAME="BETR Room Control"
APP_BUNDLE=""
EXPECTED_MODE="embeddedSMAppService"
STAGED_APP_BUNDLE=""
BACKUP_APP_BUNDLE=""
CORE_SUPPORT_DIR="$HOME/Library/Application Support/BETRCoreAgentV3"
BACKUP_CORE_SUPPORT_DIR=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --configuration <debug|release>   Build artifact configuration. Default: debug
  --app-bundle <path>               Override the app bundle to validate
  --expected-mode <mode>            Require bootstrap mode (default: embeddedSMAppService)
  --help                            Show this message
EOF
}

plist_value() {
  local plist_path="$1"
  local key_path="$2"
  /usr/libexec/PlistBuddy -c "Print ${key_path}" "$plist_path" 2>/dev/null
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration)
      CONFIGURATION="$2"
      shift 2
      ;;
    --app-bundle)
      APP_BUNDLE="$2"
      shift 2
      ;;
    --expected-mode)
      EXPECTED_MODE="$2"
      shift 2
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

if [[ -z "$APP_BUNDLE" ]]; then
  APP_BUNDLE="$PROJECT_DIR/build/artifacts/$CONFIGURATION/${APP_NAME}.app"
fi

cleanup() {
  launchctl bootout "gui/$(id -u)/com.betr.core-agent" >/dev/null 2>&1 || true
  pkill -x BETRCoreAgent >/dev/null 2>&1 || true
  if [[ -n "$STAGED_APP_BUNDLE" ]]; then
    rm -rf "$STAGED_APP_BUNDLE"
  fi
  if [[ -n "$BACKUP_APP_BUNDLE" && -d "$BACKUP_APP_BUNDLE" ]]; then
    rm -rf "/Applications/${APP_NAME}.app"
    ditto "$BACKUP_APP_BUNDLE" "/Applications/${APP_NAME}.app"
    rm -rf "$BACKUP_APP_BUNDLE"
  fi
  if [[ -n "$BACKUP_CORE_SUPPORT_DIR" && -d "$BACKUP_CORE_SUPPORT_DIR" ]]; then
    rm -rf "$CORE_SUPPORT_DIR"
    ditto "$BACKUP_CORE_SUPPORT_DIR" "$CORE_SUPPORT_DIR"
    rm -rf "$BACKUP_CORE_SUPPORT_DIR"
  fi
}

trap cleanup EXIT

if [[ "$APP_BUNDLE" != "/Applications/${APP_NAME}.app" ]]; then
  STAGED_APP_BUNDLE="/Applications/${APP_NAME}.app"
  if [[ -d "$STAGED_APP_BUNDLE" ]]; then
    BACKUP_APP_BUNDLE="$(mktemp -d)/${APP_NAME}.app"
    ditto "$STAGED_APP_BUNDLE" "$BACKUP_APP_BUNDLE"
    rm -rf "$STAGED_APP_BUNDLE"
  fi
  ditto "$APP_BUNDLE" "$STAGED_APP_BUNDLE"
  APP_BUNDLE="$STAGED_APP_BUNDLE"
fi

if [[ -n "$EXPECTED_MODE" && "$EXPECTED_MODE" != "embeddedSMAppService" && "$EXPECTED_MODE" != "embeddedLaunchAgent" ]]; then
  echo "ERROR: --expected-mode must be embeddedSMAppService or embeddedLaunchAgent."
  exit 1
fi

INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
HELPER_PATH="$APP_BUNDLE/Contents/Helpers/BETRCoreAgent"
NETWORK_HELPER_PATH="$APP_BUNDLE/Contents/Helpers/BETRNetworkHelper"
LAUNCH_AGENT_PLIST="$APP_BUNDLE/Contents/Library/LaunchAgents/com.betr.core-agent.plist"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
APP_ICON_ICNS="$APP_BUNDLE/Contents/Resources/AppIcon.icns"

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "ERROR: App bundle not found at '$APP_BUNDLE'."
  exit 1
fi

if [[ ! -x "$APP_EXECUTABLE" ]]; then
  echo "ERROR: App executable is missing at '$APP_EXECUTABLE'."
  exit 1
fi

if [[ ! -x "$HELPER_PATH" ]]; then
  echo "ERROR: Embedded BETRCoreAgent helper is missing at '$HELPER_PATH'."
  exit 1
fi

if [[ ! -x "$NETWORK_HELPER_PATH" ]]; then
  echo "ERROR: Embedded BETRNetworkHelper helper is missing at '$NETWORK_HELPER_PATH'."
  exit 1
fi

if [[ ! -f "$LAUNCH_AGENT_PLIST" ]]; then
  echo "ERROR: Bundled LaunchAgent plist is missing at '$LAUNCH_AGENT_PLIST'."
  exit 1
fi

bundle_id="$(plist_value "$INFO_PLIST" "CFBundleIdentifier")"
if [[ "$bundle_id" != "com.betr.room-control" ]]; then
  echo "ERROR: Expected CFBundleIdentifier=com.betr.room-control, got '$bundle_id'."
  exit 1
fi

icon_file="$(plist_value "$INFO_PLIST" "CFBundleIconFile")"
if [[ "$icon_file" != "AppIcon" ]]; then
  echo "ERROR: Expected CFBundleIconFile=AppIcon, got '$icon_file'."
  exit 1
fi

if [[ ! -f "$APP_ICON_ICNS" ]]; then
  echo "ERROR: App icon is missing at '$APP_ICON_ICNS'."
  exit 1
fi

launch_label="$(plist_value "$LAUNCH_AGENT_PLIST" "Label")"
bundle_program="$(plist_value "$LAUNCH_AGENT_PLIST" "BundleProgram")"
mach_service="$(plist_value "$LAUNCH_AGENT_PLIST" "MachServices:com.betr.core-agent")"

if [[ "$launch_label" != "com.betr.core-agent" ]]; then
  echo "ERROR: Expected LaunchAgent Label=com.betr.core-agent, got '$launch_label'."
  exit 1
fi

if [[ "$bundle_program" != "Contents/Helpers/BETRCoreAgent" ]]; then
  echo "ERROR: Expected BundleProgram=Contents/Helpers/BETRCoreAgent, got '$bundle_program'."
  exit 1
fi

if [[ "$mach_service" != "true" ]]; then
  echo "ERROR: Expected MachServices:com.betr.core-agent=true, got '$mach_service'."
  exit 1
fi

if [[ -n "$EXPECTED_MODE" ]]; then
  codesign --verify --deep --strict "$APP_BUNDLE"
fi

if [[ -d "$CORE_SUPPORT_DIR" ]]; then
  BACKUP_CORE_SUPPORT_DIR="$(mktemp -d)/BETRCoreAgentV3"
  if ditto "$CORE_SUPPORT_DIR" "$BACKUP_CORE_SUPPORT_DIR"; then
    rm -rf "$CORE_SUPPORT_DIR"
  else
    echo "ERROR: Failed to back up core support directory before packaged validation."
    exit 1
  fi
fi

bootstrap_output="$(
  BETR_ROOM_CONTROL_BOOTSTRAP_CHECK=1 \
  "$APP_EXECUTABLE"
)"

BOOTSTRAP_OUTPUT="$bootstrap_output" \
APP_BUNDLE="$APP_BUNDLE" \
HELPER_PATH="$HELPER_PATH" \
EXPECTED_MODE="$EXPECTED_MODE" \
python3 - <<'PY'
import json
import os
import sys

raw = os.environ["BOOTSTRAP_OUTPUT"]
app_bundle = os.environ["APP_BUNDLE"]
helper_path = os.environ["HELPER_PATH"]
expected_mode = os.environ["EXPECTED_MODE"] or None
expected_sdk_path = os.path.join(app_bundle, "Contents", "Frameworks", "libndi.dylib")

try:
    payload = json.loads(raw)
except json.JSONDecodeError as exc:
    print(f"ERROR: bootstrap-check emitted invalid JSON: {exc}", file=sys.stderr)
    sys.exit(1)

mode = payload.get("mode")
executable_path = payload.get("executablePath")
plist_path = payload.get("plistPath")

if mode not in {"embeddedSMAppService", "embeddedLaunchAgent"}:
    print(f"ERROR: packaged app used unexpected bootstrap mode: {mode}", file=sys.stderr)
    sys.exit(1)

if expected_mode and mode != expected_mode:
    print(
        "ERROR: packaged app used the wrong bootstrap mode.\n"
        f"Expected: {expected_mode}\nGot:      {mode}",
        file=sys.stderr,
    )
    sys.exit(1)

if executable_path != helper_path:
    print(
        "ERROR: packaged app did not resolve BETRCoreAgent from the bundled helper path.\n"
        f"Expected: {helper_path}\nGot:      {executable_path}",
        file=sys.stderr,
    )
    sys.exit(1)

if mode == "embeddedSMAppService":
    expected_plist = os.path.join(app_bundle, "Contents", "Library", "LaunchAgents", "com.betr.core-agent.plist")
    if plist_path != expected_plist:
        print(
            "ERROR: SMAppService bootstrap did not report the bundled LaunchAgent plist.\n"
            f"Expected: {expected_plist}\nGot:      {plist_path}",
            file=sys.stderr,
        )
        sys.exit(1)
else:
    if not plist_path.endswith("/Library/LaunchAgents/com.betr.core-agent.plist"):
        print(
            "ERROR: fallback bootstrap did not rewrite the user LaunchAgent manifest as expected.\n"
            f"Got: {plist_path}",
            file=sys.stderr,
        )
        sys.exit(1)

if payload.get("eventObservationReady") is not True:
    print("ERROR: packaged app did not confirm live event observation readiness.", file=sys.stderr)
    sys.exit(1)

if payload.get("previewTransportReachable") is not True:
    print("ERROR: packaged app did not confirm preview transport reachability.", file=sys.stderr)
    sys.exit(1)

sdk_loaded_path = payload.get("sdkLoadedPath")
for blocked in ("libndi_advanced.dylib", "/Library/NDI SDK for Apple/", "/usr/local/lib/"):
    if sdk_loaded_path and blocked in sdk_loaded_path:
        print(
            "ERROR: packaged app reported a blocked NDI SDK path.\n"
            f"Path: {sdk_loaded_path}",
            file=sys.stderr,
        )
        sys.exit(1)

if sdk_loaded_path != expected_sdk_path:
    print(
        "ERROR: packaged app did not report the bundled standard NDI SDK path.\n"
        f"Expected: {expected_sdk_path}\nGot:      {sdk_loaded_path}",
        file=sys.stderr,
    )
    sys.exit(1)

print("bootstrap mode:", mode)
print("helper path:", executable_path)
print("plist path:", plist_path)
print("outputs seen:", payload.get("outputCount"))
print("sources seen:", payload.get("sourceCount"))
print("observed output:", payload.get("observedOutputID"))
print("sdk path:", sdk_loaded_path)
print("event observation:", payload.get("eventObservationReady"))
print("preview transport:", payload.get("previewTransportReachable"))
status_message = payload.get("statusMessage")
if status_message:
    print("status:", status_message)
PY

echo "validated bundle: $APP_BUNDLE"
