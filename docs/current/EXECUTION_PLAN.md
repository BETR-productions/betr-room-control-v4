# BETR Room Control v4 Execution Plan

- owner: unassigned
- status: current
- applies_to: `betr-room-control-v4`
- last_verified: 2026-03-29

## Phase: Shell Bootstrap
- [x] Create package skeleton and repo-local docs front door.
- [x] Reintroduce the preserved operator shell surface with compile-safe placeholder data.
- [x] Create a new `RoomControlWorkspaceStore` adapter seam backed by a single `BETRCoreAgentClient` placeholder.
- [ ] Replace placeholder workspace projection with real `BETRCoreXPC` command and event wiring.
- [ ] Restore the grouped NDI wizard semantics against real host/apply/validate commands.

### Done When
- `RoomControlApp` boots the preserved shell structure from one store.
- No app-owned NDI runtime or split-XPC ownership leaks into the new repo.
- The package is ready to consume `betr-core-v3` as the single runtime boundary.

## Phase: Discovery Stability
- [x] Replace the bare managed-agent recycle flag with a one-shot restart intent record
- [x] Map core agent process identity through workspace and validation snapshots
- [x] Show bounded Discovery warmup truth after an intentional recycle instead of failure copy during listener bring-up
- [ ] Prove the real apply/relaunch flow on a Discovery Server network without repeated agent churn

### Done When
- Intentional `Apply + Restart` produces one helper recycle and one new agent instance
- Ordinary refreshes keep the same agent identity and do not reset discovery ownership
- The top Discovery card stays truthful during warmup without inventing source visibility or transport health
