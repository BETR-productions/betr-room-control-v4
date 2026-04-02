# BETR Room Control v4 Compass Media Rebuild

- owner: codex
- status: current
- applies_to: `betr-room-control-v4`
- source_of_truth: `../../../../betr-docs/current/ndi/compass_artifact_wf-e70011ae-0052-42e5-9ede-7295d0976b88_text_markdown.md`
- last_verified: 2026-04-01

## Guardrail

- This file tracks app wiring only. It must not restate or override the Compass media spec.

## Gate Status

- Main preflight/CodeRabbit review: pending final rerun
- Repo truth: complete
- Local packaged release truth: complete
- Real test machine acceptance: pending
- Merge/publish: blocked until main preflight/CodeRabbit review is clean and the signed + notarized + stapled `0.4.1.2` artifact passes first-launch and persisted-host-profile relaunch on the real test machine

## Wave Status

Progress: 90% — app wiring and local release validation complete; real test machine acceptance pending

- [x] Preserve the existing Room Control shell, discovery list, slot actions, and wizard flow as the fixed UX boundary.
- [x] Restore the deleted app runtime/client/workspace files so the preserved UX can build against the rebuilt core line again.
- [x] Point repo guidance at the Compass media authority instead of the removed reset-era docs.
- [x] Keep the current command surface unchanged while rewiring it to per-output media chains:
  `assignSource`, `clearSlot`, `setPreviewSlot`, `takeProgramSlot`, output mute/solo, preview attachments, live-tile events.
- [x] Remove stale fallback naming from the preserved shell without changing the UX layout or operator-facing flows.
- [x] Remove remaining stale media assumptions from app-side contracts and mappings.
- [x] Prove `PVW` = full warm standby and `PGM` cold-take = existing `ARMING` state until ready-gated cut.
- [x] Generalize the rebuilt output chain across every output with no UX redesign and no discovery/find changes.
- [x] Pass local signed/notarized/stapled packaged validation with `embeddedSMAppService`, bundled helper bootstrap, and bundled standard SDK load from `Contents/Frameworks/libndi.dylib`.
- [ ] Pass the same signed/notarized artifact on the real test machine, including persisted-host-profile relaunch.

## Done When

- Room Control keeps the current operator workflow while all media truth comes from the Compass-based core chain.
- The app no longer carries any alternate media-path assumptions or fallback semantics.
- The packaged app and bundled helper pass real-machine launch and relaunch acceptance without falling back to any non-bundled SDK path.
