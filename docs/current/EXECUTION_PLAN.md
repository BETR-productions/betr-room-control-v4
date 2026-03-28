# BETR Room Control v4 Execution Plan

- owner: unassigned
- status: current
- applies_to: `betr-room-control-v4`
- last_verified: 2026-03-22

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
