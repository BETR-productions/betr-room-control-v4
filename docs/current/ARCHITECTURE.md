# BETR Room Control v4 Architecture

- owner: unassigned
- status: current
- applies_to: `betr-room-control-v4`
- last_verified: 2026-03-22

## Role
- Operator-facing macOS app for the restart line.
- Depends on `betr-core-v3` for runtime ownership through one `BETRCoreAgent` boundary.
- Preserves the V3 shell, grouped NDI settings flow, and operator action surface.

## Current Boundary
- `RoomControlUIContracts` owns operator-facing shell and wizard state.
- `FeatureUI` owns SwiftUI and AppKit presentation only.
- `RoutingDomain` owns the `BETRCoreAgentClient` seam and workspace projection.
- The app must not recreate the legacy split-XPC or app-owned NDI runtime model.
