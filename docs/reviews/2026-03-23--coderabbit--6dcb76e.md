# CodeRabbit Review — `6dcb76e`

- date: 2026-03-23
- repo: `betr-room-control-v4`
- base: `main`
- verdict: `PASS WITH NOTES`

## Scope Reviewed
- Settings hotfix for:
  - explicit settings exit path
  - restored advanced NDI host controls
  - safe proof-mode defaults that do not silently disable internet-facing services
  - host profile passthrough for ownership, node label, extra IPs, and receive subnets

## Findings
1. `Sources/FeatureUI/BrandTokens.swift`
   - CodeRabbit noted that `liveRed` is a misleading name for a dark surface token.
   - Resolution: carried forward as a non-blocking naming cleanup because it is unrelated to the hotfix and does not affect shipped behavior.
2. `Package.swift`
   - CodeRabbit noted that `RoomControlApp` lists some transitive dependencies explicitly.
   - Resolution: left as-is for this bridge hotfix because the manifest is currently stable and the redundant entries are harmless.
3. `Sources/PresentationDomain/PresentationModels.swift`
   - CodeRabbit suggested a future `recovering` phase for XPC crash recovery.
   - Resolution: carried forward as a later runtime-state enhancement because it is outside this settings/network hotfix scope.

## Notes
- No blocking findings were raised against the committed hotfix diff.
- The shipped behavior change is intentional:
  - the settings sheet now has an explicit `Done` exit
  - the old advanced host controls are visible again
  - Wi-Fi and bridge-service shutdown remain opt-in instead of silently inheriting core proof-mode defaults
