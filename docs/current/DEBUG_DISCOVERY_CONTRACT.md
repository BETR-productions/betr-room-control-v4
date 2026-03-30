# Debug Discovery Contract

- owner: unassigned
- status: current
- applies_to: `betr-room-control-v4`
- last_verified: 2026-03-30

## Rule
- Default Room Control discovery UI must consume SDK-authoritative product fields only.
- Discovery diagnostics may appear only in the explicit `DEBUG ONLY` surface.
- Apply-card config copy must describe configured discovery state, not runtime discovery state.

## Default UI Inputs
- `sdkBootstrapState`
- listener create success
- listener connected state
- listener connected server URL
- visible remote source state from `NDI-FIND`

## Debug-Only Inputs
- validated address
- debug listener state
- candidate addresses
- attach attempt counts
- last attempted addresses
- attach failure reasons
- config path
- SDK path and version

## Bans
- Do not use debug fields for status color, status word, or top-level copy.
- Do not request debug discovery data during ordinary validation refresh.
- Do not persist the `DEBUG ONLY` toggle across launches.
- Do not treat configured endpoints as connected-server truth when the SDK has not reported a real server URL.
- Do not use `mDNS only` or `Not connected` in the Apply card's configured discovery summary.
