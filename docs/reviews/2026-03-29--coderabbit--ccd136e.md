# CodeRabbit Review — `ccd136e`

- Date: 2026-03-29
- Repo: `betr-room-control-v4`
- Base: `b65c340`
- Verdict: `ESCALATED`

## Scope Reviewed
- Discovery-5 Room Control updates for:
  - one-shot managed-agent restart intent handling
  - additive core-agent identity mapping
  - Discovery warmup-truth UI during intentional relaunch
  - bridge default version bump to `0.9.8.84`

## CodeRabbit Findings
1. Initial review of `d0adb74` reported one non-blocking nitpick:
   - explicit cleanup was missing for the temporary app bundle directory created in [RoomControlCoreAgentBootstrapperTests.swift](/Users/joshperlman/Developer/betr/worktrees/betr-room-control-v4--discovery-5-warmup-truth/Tests/RoomControlScaffoldTests/RoomControlCoreAgentBootstrapperTests.swift)
2. That nitpick was fixed in follow-up commit `ccd136e` by adding a `defer` cleanup for the temporary directory in the test.
3. Rerun command attempted on `ccd136e`:
   - `coderabbit review --plain --no-color --type committed --base origin/main --cwd /Users/joshperlman/Developer/betr/worktrees/betr-room-control-v4--discovery-5-warmup-truth -c /Users/joshperlman/Developer/betr/coderabbit/.coderabbit.yaml /Users/joshperlman/Developer/betr/AGENTS.md /Users/joshperlman/Developer/betr/macos-apps/betr-room-control-v4/AGENTS.md /Users/joshperlman/Developer/betr/coderabbit/profiles/macos-swift.md`
4. Rerun result:
   - the CLI progressed through startup and review phases but stalled without emitting any additional findings or a terminal summary
5. Escalation reason:
   - CodeRabbit tooling did not complete the post-fix rerun, so final signoff relies on the fixed first-pass nitpick, manual engineering review of the final delta, and fresh test verification

## Manual Engineering Review
- Verdict: `PASS WITH NOTES`
- Claimed task:
  - stop repeated managed-agent restart churn and replace false aggregate discovery failure copy with warmup-truth UI tied to real core-agent process identity
- What was actually delivered:
  - the bootstrapper now persists a one-shot restart intent with reason and optional host fingerprint, and `ensureStarted()` consumes it once
  - workspace and validation snapshots now map additive `agentInstanceID` and `agentStartedAt` through the client and UI contracts
  - `RoomControlWorkspaceStore` now maintains a bounded Discovery warmup state keyed to the current agent instance and uses neutral `CHECK` / warmup copy while listeners are still bringing up
  - the release default in `scripts/build-app.sh` now advances from `0.9.8.83` to `0.9.8.84`
  - the only post-review code delta is the temp-directory cleanup in the bootstrapper test
- What matches the plan:
  - no new TCP probe, reachability loop, or synthetic NDI health layer was added
  - the top Discovery card no longer needs to invent sticky discovery truth across restarts
  - intentional restart context is app-local and bounded to messaging only
- Open blockers:
  - live Discovery Server proof is still required before declaring the runtime churn issue fully closed in the field
- Completion decision:
  - Task may be marked complete: `yes`
  - Commit should be blocked: `no`
  - Merge should be blocked: `no`

## Verification
- `BETR_CORE_DIR=/Users/joshperlman/Developer/betr/worktrees/betr-core-v3--discovery-5-warmup-truth swift test --package-path /Users/joshperlman/Developer/betr/worktrees/betr-room-control-v4--discovery-5-warmup-truth`
- `git -C /Users/joshperlman/Developer/betr/worktrees/betr-room-control-v4--discovery-5-warmup-truth diff --check`
