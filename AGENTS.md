# AGENTS.md -- betr-room-control-v4

## Read First
- `../../AGENTS.md`
- `./docs/current/INDEX.md`
- `./docs/current/STATUS.md`
- `../../betr-docs/current/TASK_AND_LOG_PROTOCOL.md`
- `../../betr-docs/current/CODERABBIT_LOCAL_CLI.md`
- `../../betr-docs/current/room-control/PRESENTATION_AUTOMATION.md`
- `../../betr-docs/current/room-control/TESTING.md`
- `../../betr-docs/current/room-control/NDI_WIZARD_SOURCE_OF_TRUTH.md`

## Repo Rules
- This is the restart-line Room Control app for the new core-agent architecture.
- Preserve the V3 operator shell, grouped NDI wizard flow, and operator-facing action surface unless the shared docs are updated first.
- Do not carry forward app-owned NDI runtime ownership or the old split-XPC topology behind the preserved UI.
- Keep package wiring pointed at `betr-core-v3` through `BETR_CORE_DIR` or the default sibling checkout. Do not repoint the live-line core symlink.
- Update repo-local docs/current files when architecture, release posture, or operator-visible behavior changes.
