---
name: babysit-pr
description: Watch a PR through CI and review feedback, fixing issues until green without merging. Use when the user says "babysit", "watch the PR", or "watch PR".
---

# Babysit PR

Own the PR until CI and review feedback are green. Handle routine fixes yourself; bring the user only genuine blockers or product decisions. Marking ready and merging belong to `full-stop` and `full-send`.

## 1. Prepare

- Use the attached PR or the current branch's PR (drafts included). If none exists yet, run `commit-pr` first.
- If the PR is behind or conflicting with its base branch, rebase onto the base and push with `git push --force-with-lease`.

## 2. Check, then watch

Evaluate the PR's current state first (`pull_request_read` with `sections: ["summary", "checks", "conversation"]`, or `gh pr view` / `gh pr checks`):

- Handle any existing CI failures or unresolved review comments with `pradd` and push fixes.
- Skip watching and go straight to **4. Hand back** only if already ready: when run standalone, checks and automated reviews are green on the current `HEAD` with nothing pending; when invoked by `full-send`, the full merge gate (including required approvals) already passes. (Do not start a watch on an already-ready PR, because `watch_pull_request` treats existing state as baseline and will not wake.)
- Otherwise, pick one watcher based on your tools:
  - **`watch_pull_request` is available (T3 Code):** Call `watch_pull_request` (`until: "checks"` by default, or `until: "merged"` when invoked by `full-send`) and end the turn. Do not poll or sleep.
  - **Outside T3:** Run `gh pr checks --watch`, then run **3. On each wake** (if fixes are pushed, re-run `gh pr checks --watch` on the new `HEAD`). Once checks pass, poll `gh pr view --json reviews,comments,reviewDecision,mergeStateStatus` every 2 minutes (up to 30 minutes), running **3. On each wake** on each poll when new feedback or branch drift appears, until review bots have posted on the current `HEAD` — or, when invoked by `full-send`, until the full merge gate (including required approvals) passes. If the 30-minute window expires, stop and report what requirement is still pending.

Only the thread that owns the PR watches it; a delegated child task hands back to its parent instead.

## 3. On each wake

- Confirm checks belong to the current `HEAD` (`pull_request_read` with `sections: ["summary", "checks", "conversation"]`); results for an older `HEAD` do not count. For approvals, rely on the host's current review decision (and check review `commit_id` via `gh api` when a current-`HEAD` review is required).
- Run `pradd` for new CI failures and unresolved review comments.
- If a check looks flaky or unrelated to the PR, rerun it once (`ci_rerun` or `gh run rerun <run-id> --failed`) before treating it as caused by this change.
- Check `mergeStateStatus`: if `BEHIND` or `DIRTY`, rebase and push with `--force-with-lease` (`watch_pull_request` wakes on conflicts, not behind).
- Fixes prompted by CI or review count against a budget of **3 fix rounds**. Past that, stop and hand back.

## 4. Hand back

When checks and automated reviews are green on the latest `HEAD`, when blocked, or when only the user can answer a question or approve:

- Call `unwatch_pull_request` (unless a caller such as `full-send` is continuing to merge).
- Report the PR URL, current `HEAD` SHA, checks and reviews state, fixes applied, and any remaining blocker or human approval needed.

---

Adapted from Theo Browne's skills and Mikael Siidorow's `systems` under the [MIT license](LICENSE).
