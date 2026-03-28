# CodeRabbit Review — `39ac3a8`

- date: 2026-03-26
- repo: `betr-room-control-v4`
- base: `HEAD^`
- verdict: `ESCALATED`

## Scope Reviewed
- Settings hotfix for:
  - a real `Restart Now` prompt after `Start Over`
  - simpler NIC selection in the NDI wizard
  - clearer selected / live NIC status in the operator flow
  - bridge release metadata update to `0.9.8.57`

## CodeRabbit Runner Notes
1. The repo-local wrapper defaulted to `origin/main`, but this worktree still has the unrelated-history remote-base condition, so `origin/main...HEAD` failed with `no merge base`.
2. A fallback run against `HEAD^` reached the CodeRabbit service, then failed on a platform rate limit before findings were returned.
3. Log evidence:
   - no-merge-base failure from the committed wrapper run on 2026-03-26
   - rate-limit failure from the `--base-commit HEAD^` fallback run on 2026-03-26

## Manual Engineering Review
- Verdict: `PASS WITH NOTES`
- The shipped behavior matches the operator complaint:
  - `Start Over` now ends with a restart decision instead of a silent status-only finish
  - the NIC step no longer shows a redundant giant card list beside the actual dropdown
  - the selected NIC, committed NIC, runtime NIC, and route owner are now visible in one compact block
- The change is structural enough to be worth shipping:
  - the restart affordance is wired through store state, not just a local transient button hack
  - the NIC UI simplification removes the duplicate selection path instead of masking it visually
  - the bridge version metadata and release docs were advanced in the same change set

## Notes
- No blocking defects were found in the manual review.
- CodeRabbit evidence is escalated only because the runner was blocked by repo-history shape and then service rate limiting, not because the code changes themselves were rejected.
