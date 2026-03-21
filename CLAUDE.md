# BËTR Room Control v4 — Agent Instructions

## What this repo is
The operator application for BËTR live event production. Built on BËTR Core v3.
Three-column SwiftUI layout. All UI and app-specific logic lives here.

## What it must never contain
- Direct NDI SDK imports or calls
- NDIlib_* function calls of any kind
- Code that creates NDI receiver or sender handles

## Reference repo
~/Developer/betr/betr-room-control-v3 — read for UI patterns and features.
Key files:
- Sources/FeatureUI/BrandTokens.swift — COPY EXACTLY, do not change hex values
- Sources/FeatureUI/RestoredRoomControlShellView.swift — three-column layout to preserve
- Sources/FeatureUI/RoomControlSettingsRootView.swift — NDI wizard UI to preserve
- scripts/build-app.sh — copy and update for v4
- scripts/release-public.sh — copy and update for v4

## Module ownership
| Module | Owner Agent | Branch |
|--------|-------------|--------|
| FeatureUI, RoomControlApp | UIShell | ui-shell |
| ClipPlayerDomain, TimerDomain | FeatureProducers | feature-producers |
| PresentationDomain | PresentationDomain | presentation-domain |
| scripts/, Resources/ (icons, DMG) | ReleasePipeline | release-pipeline |
| RoutingDomain, PersistenceDomain | UIShell | ui-shell |

## Core dependency
betr-core-v3 is at ~/Developer/betr/betr-core-v3
Set BETR_CORE_DIR=~/Developer/betr/betr-core-v3 for all build commands.

## Brand rules (non-negotiable)
- All colors from BrandTokens only — no hardcoded hex
- App background: BrandTokens.dark (#1A1A1A)
- Gold accent: BrandTokens.gold (#FFAD33)
- Three-column resizable layout preserved
- Slot cells: 108pt min width, 112pt height, PVW+PGM buttons always visible
- Font: Inter (display) + SF Mono (mono values)

## Verification commands
- Tests: `BETR_CORE_DIR=~/Developer/betr/betr-core-v3 swift test`
- Build: `BETR_CORE_DIR=~/Developer/betr/betr-core-v3 swift build`
- Full preflight: `BETR_CORE_DIR=~/Developer/betr/betr-core-v3 bash scripts/preflight.sh`

## Versioning
First release: 0.3.21 (month.day format)
CFBundleShortVersionString: "0.3.21"
Use date of release as version: March 21 = 0.3.21, April 1 = 0.4.1

## Signing (local only — never GitHub Actions)
Identity: "Developer ID Application: Joshua Perlman (Y8WQ4W4L59)"
Notarytool profile: notarytool (in Keychain)
Release: scripts/release-public.sh --sign --notarize --staple
