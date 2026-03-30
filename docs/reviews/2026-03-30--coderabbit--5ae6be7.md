# CodeRabbit Review — `5ae6be7`

- Date: 2026-03-30
- Repo: `betr-room-control-v4`
- Base: `3022162`
- Verdict: `ESCALATED`

## Scope Reviewed
- Discovery-7D app cleanup for:
  - making the Apply card read as configuration state instead of runtime state
  - adding a config-only discovery summary helper with `None` as the empty value
  - preserving runtime-only wording such as `mDNS only` and `Not connected` for the live runtime card
  - bumping the default bridge release version in `scripts/build-app.sh` from `0.9.8.87` to `0.9.8.88`

## CodeRabbit Findings
1. Local CodeRabbit review was attempted with:
   - `REPO_DIR=/Users/joshperlman/Developer/betr/worktrees/betr-room-control-v4--discovery-7d-debug-read-path BETR_ROOT=/Users/joshperlman/Developer/betr APP_PROFILE=/Users/joshperlman/Developer/betr/coderabbit/profiles/macos-swift.md /Users/joshperlman/Developer/betr/scripts/coderabbit-local-review-common.sh --type committed --base origin/main`
2. The CLI failed before review startup with a platform rate-limit response:
   - `Rate limit exceeded, please try after 5 minutes and 32 seconds`
3. No code findings were returned, so the review is recorded as `ESCALATED` for tooling availability rather than for a content rejection.

## Manual Engineering Review
- Verdict: `PASS`
- What was checked:
  - `RoomControlSettingsRootView` now labels the Apply card `Configured Discovery Server(s)`
  - empty configured discovery text now renders as `None`
  - runtime summary wording remains untouched and still distinguishes `mDNS only` from `Not connected`
  - `RoomControlSettingsRootViewTests` cover empty, single-entry, and multiline configured discovery summaries
  - the only release metadata change is the `DEFAULT_VERSION` bump to `0.9.8.88` in `scripts/build-app.sh`
- Completion decision:
  - Task may be marked complete: `yes`
  - Commit should be blocked: `no`
  - Merge should be blocked: `no`
  - Release should be blocked: `no`, with the CodeRabbit rate-limit escalation recorded

## Verification
- `BETR_CORE_DIR=/Users/joshperlman/Developer/betr/worktrees/betr-core-v3--discovery-7d-debug-read-path swift test --package-path /Users/joshperlman/Developer/betr/worktrees/betr-room-control-v4--discovery-7d-debug-read-path`
- `git -C /Users/joshperlman/Developer/betr/worktrees/betr-room-control-v4--discovery-7d-debug-read-path diff --check`
- CodeRabbit rate-limit log:
  - `/Users/joshperlman/.coderabbit/logs/2026-03-30T15-51-42-179Z-coderabbit-cli-88763d18-d590-45d5-8e6e-6a044bccf179.log`
