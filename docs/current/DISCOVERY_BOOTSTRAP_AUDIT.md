# Discovery-7 App Boundary Audit

- owner: unassigned
- status: current
- applies_to: `betr-room-control-v4`
- last_verified: 2026-03-30

## Purpose
- Record the Room Control side of the Discovery-7 repair so the UI/bootstrap layer does not drift back into outracing the helper.
- Pair this with the core-side audit in the companion `betr-core-v3` worktree: `docs/current/DISCOVERY_BOOTSTRAP_AUDIT.md`

## App-Side Audit Findings
- Room Control still polled the helper immediately after launch, while helper bootstrap work could still be in flight.
- `waitForAgentAvailability()` still used the short generic timeout path unless a caller manually overrode it, which made first-launch readiness too brittle for the new startup barrier.
- The app needed to treat helper readiness as “bootstrap complete,” not just “Mach service answered once.”

## Discovery-7 App Corrections
1. Helper readiness is now barrier-backed.
   - `BETRCoreAgent` blocks XPC-backed runtime work until startup bootstrap is complete.
   - Room Control no longer wins a race by touching snapshots before the helper has committed config and initialized NDI.
2. Agent availability now uses a startup-appropriate request timeout.
   - `BETRCoreAgentClient.waitForAgentAvailability()` now retries with a longer readiness request timeout instead of the short generic path.
   - The call still retries and still invalidates stale channels between attempts.
3. Workspace snapshot reads now accept an explicit timeout override.
   - Startup/readiness waits can use a bootstrap-sized timeout.
   - Non-startup operations continue to use the normal generic timeout path.

## References
- [NDI Startup and Shutdown](https://docs.ndi.video/all/developing-with-ndi/sdk/startup-and-shutdown)
- [NDI Configuration Files](https://docs.ndi.video/all/developing-with-ndi/sdk/configuration-files)
- [NDI-FIND](https://docs.ndi.video/all/developing-with-ndi/sdk/ndi-find)
- `Tractus launcher`: local example path `${TRACTUS_APP_DIR}/Contents/Resources/script`
- `Tractus engine`: local example path `${TRACTUS_APP_DIR}/Contents/Resources/Tractus.Ndi.Multiview.SWEngine`
- Replace `${TRACTUS_APP_DIR}` with the Tractus app path on the machine you are auditing.

## Verification
- `BETR_CORE_DIR="${BETR_CORE_WORKTREE:-/path/to/betr-core-v3}" swift test --package-path "${BETR_ROOM_CONTROL_WORKTREE:-$PWD}"`
- Startup client regression:
  - `waitForAgentAvailability()` still retries after a timeout
  - readiness waits no longer inherit the short generic timeout by accident
