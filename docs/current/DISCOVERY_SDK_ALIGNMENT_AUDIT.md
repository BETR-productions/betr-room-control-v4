# Discovery SDK Alignment Audit

- owner: unassigned
- status: current
- applies_to: `betr-room-control-v4`
- last_verified: 2026-03-30

## Verdict
- `ALIGNED ENOUGH TO CONTINUE`
- This is the app-boundary side of the Discovery-7 code audit.
- The canonical combined cross-repo verdict table lives in the companion core note:
  - [core Discovery SDK alignment audit](/Users/joshperlman/Developer/betr/worktrees/betr-core-v3--discovery-7-single-init-sdk-main/docs/current/DISCOVERY_SDK_ALIGNMENT_AUDIT.md)
- The app now consumes a product-only discovery contract by default, with diagnostics isolated behind:
  - [DEBUG_DISCOVERY_CONTRACT.md](/Users/joshperlman/Developer/betr/worktrees/betr-room-control-v4--discovery-7-single-init-sdk-main/docs/current/DEBUG_DISCOVERY_CONTRACT.md)

## References
- [NDI Startup and Shutdown](https://docs.ndi.video/all/developing-with-ndi/sdk/startup-and-shutdown)
- [NDI Platform Considerations](https://docs.ndi.video/all/developing-with-ndi/sdk/platform-considerations)
- [NDI Configuration Files](https://docs.ndi.video/all/developing-with-ndi/sdk/configuration-files)
- [NDI-FIND](https://docs.ndi.video/all/developing-with-ndi/sdk/ndi-find)
- [NDI Recv Discovery, Monitor, and Control](https://docs.ndi.video/all/developing-with-ndi/sdk/ndi-recv-discovery-monitor-and-control)
- [NDI Sender Listener](https://docs.ndi.video/all/developing-with-ndi/sdk/ndi-sender-discovery-and-monitor/ndi-sender-listener)
- [Tractus launcher](/Users/joshperlman/Downloads/Tractus%20Multiview%20for%20NDI%20%28SWEngine%29.app/Contents/Resources/script)
- [Tractus engine](/Users/joshperlman/Downloads/Tractus%20Multiview%20for%20NDI%20%28SWEngine%29.app/Contents/Resources/Tractus.Ndi.Multiview.SWEngine)

## Tractus Runtime Evidence
- The live Tractus wrapper still launches a shell script that only execs the engine binary.
- The live Tractus engine still owns embedded `libndi_advanced.dylib`.
- The live Tractus engine still owns the Discovery Server socket attempt to `192.168.55.11:5959`.
- This remains the runtime-shape baseline for BETR:
  - UI shell does not own NDI bootstrap
  - helper/engine owns SDK loading and discovery transport

## Pass/Fail Checklist By Subsystem
- **Helper readiness contract**: `PASS`
  - app startup now waits for helper bootstrap completion instead of racing the helper.
- **Agent availability timeout**: `PASS`
  - startup availability uses a bootstrap-sized workspace snapshot timeout.
- **Connected-server truth**: `PASS`
  - app mapping no longer falls back from “configured endpoint” to “connected server.”
- **Discovery state authority**: `PASS`
  - app aggregate discovery state keys off visible sources, connected listeners, listener create success, and bootstrap state only.
- **Diagnostics exposure boundary**: `PASS`
  - diagnostics were removed from the default row contract and now render only in the explicit `DEBUG ONLY` surface.
- **Operator copy drift risk**: `PASS`
  - default discovery copy is SDK-shaped and debug diagnostics are clearly labeled non-authoritative.

## PASS Findings
- `BETRCoreAgentClient.waitForAgentAvailability()` now uses a startup-sized request timeout instead of the short generic timeout path.
- Workspace snapshot reads support a timeout override, which keeps startup readiness separate from ordinary runtime commands.
- `activeDiscoveryServerURL` mapping uses connected URLs and runtime active-server values only.
- `makeDiscoveryState(...)` no longer treats configured endpoints as connected-state truth.
- The bootstrapper still uses explicit restart intent rather than ordinary refresh-driven recycle behavior.

## RISK Findings
- None identified in the current app-boundary code audit.

## FAIL Findings
- None identified in this app-boundary code audit.

## Must Remove
- No blocking app-side non-SDK discovery authority was identified in the current code audit.

## May Keep As Debug-Only
- candidate addresses
- attach attempt counts
- attach failure details
- diagnostics-only wording that explains listener bring-up without claiming connection truth

## Confirmed SDK-Aligned
- app startup waits for helper bootstrap instead of outrunning it
- connected-server truth comes from core SDK-backed runtime fields
- aggregate discovery state is driven by bootstrap state, visible sources, listener create success, and listener status, not synthetic TCP health
- default discovery rows are product-only and SDK-shaped
- debug discovery data is fetched only through the dedicated debug snapshot path
- restart intent remains explicit and one-shot

## Required Follow-up
- Validate the current app mapping against the next remote-machine proof run.
  - if the helper is stable and the source catalog still disappears, treat that as a core/runtime issue
  - do not add app-side fallback truth to hide it
