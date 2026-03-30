# BETR Room Control v4 Receive / Output Audio-Sync Guardrails

- owner: unassigned
- status: current
- applies_to: `betr-room-control-v4`
- last_verified: 2026-03-30

## Rules
- The app consumes output-thumbnail audio state from the helper-owned output live-tile contract only.
- `audioPresenceState`, `leftLevel`, and `rightLevel` on output live-tile models represent the audio actually being published by that output.
- Output-thumbnail meters must not be synthesized from:
  - source readiness
  - receiver telemetry
  - cue bus state
  - selected-preview state
- Preview-only source thumbnails may stay lightweight and video-first, but they do not become routed program audio authority in the UI contract.
- Program/prewarm/output readiness still depends on helper-side frame-sync-owned audio/video readiness and the published live-tile state that comes back from core.

## UI Meaning
- `LIVE` tile image: current output image.
- Meter bars on that tile: current output audio levels after mute/silence handling.
- `muted`: output is publishing muted audio.
- `silent`: output is publishing silence or has no live program audio.

## References
- Core media timing policy lives in the paired core note:
  - `betr-core-v3/docs/current/RECEIVE_OUTPUT_AUDIO_SYNC_GUARDRAILS.md`
- Tractus remains a runtime-shape comparison only.
