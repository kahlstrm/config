---
name: babysit-pr
description: Watch a PR through CI and review feedback, fixing issues until green without merging. Use when the user says "babysit", "watch the PR", "watch PR", "fix CI", or "address PR comments".
---

# Babysit PR

Own the PR until CI and review feedback are green. Handle routine fixes yourself; bring the user only genuine blockers or product decisions. Marking ready and merging belong to `full-stop` and `full-send`.

In a stack with no explicit PR target, operate on the unmerged layers of the stack.

## 1. Prepare

- Use an explicit or attached open PR first, then fall back to the current branch's open PR (drafts included); if an explicitly named PR is closed or merged, report its state and stop. If no open PR exists yet, run `commit-pr` first.
- If the PR is behind or conflicting with its base branch, rebase onto the base and push with `git push --force-with-lease`.

## 2. Check, then watch

- Read the PR's current state (`pull_request_read` with `include: ["checks", "threads", "comments"]`, or `gh pr view` / `gh pr checks`).
- Address any existing CI failures or unresolved review comments (section **3. Address CI & review feedback**) and push fixes.
- Skip watching and go straight to **5. Hand back** only if already ready: when run standalone, checks and automated reviews are green on the current `HEAD` with nothing pending; when invoked by `full-send`, the full merge gate (including required approvals) already passes. (Do not start a watch on an already-ready PR, because `watch_pull_request` treats existing state as baseline and will not wake.)
- Otherwise, start one watcher (only the thread owning the PR watches it; a delegated child hands back to its parent instead):
  - **`watch_pull_request` is available (T3 Code):** Call `watch_pull_request` (`until: "checks"` by default, or `until: "merged"` when invoked by `full-send`) and end the turn. Do not poll or sleep.
  - **Outside T3:** Run `gh pr checks --watch`, then run **4. On each wake** (re-running `gh pr checks --watch` after any push). Once checks pass, poll `gh pr view --json reviews,comments,reviewDecision,mergeStateStatus` every 2 minutes (up to 30 minutes), running **4. On each wake** whenever new feedback or branch drift appears, until review bots have posted on the current `HEAD` — or, when invoked by `full-send`, until the full merge gate passes. If the 30-minute window expires, stop and report what remains pending.

## 3. Address CI & review feedback

Prefer T3 PR tools (`pull_request_read`, `ci_logs`) over `gh` when available. If the caller has not already fetched the PR state, read it first (`pull_request_read` with `include: ["checks", "threads", "comments"]`, or `gh pr view` / `gh pr checks`).

- **CI failures:** Fetch logs (`ci_logs` or `gh run view <run-id> --log-failed`) and investigate alongside review comments — do not wait for pending CI before reading comments. If a check looks flaky or unrelated, rerun it once (`ci_rerun` or `gh run rerun <run-id> --failed`) before treating it as caused by this change.
- **Review comments:** Extract unresolved threads/comments (outside T3, fetch inline diff comments with `gh api repos/{owner}/{repo}/pulls/{pr_number}/comments` if missing). Summarize each in one line (author, file:line, requested change).
- **Triage & fix:** Validate each finding against the code and intended behavior. Fix clear bugs and regressions within scope without asking; ask only when a finding requires a product decision, changes access/isolation, materially expands scope, or has meaningful tradeoffs. Explain any rejected findings. Preserve existing approval rules for external communication and deployment.
- **Verify & push:** Run affected checks locally and push. Completing review fixes does not mean the PR is ready to merge while checks are pending.

## 4. On each wake

- Confirm checks belong to the current `HEAD` (`pull_request_read` with `include: ["checks", "threads", "comments"]`); results for an older `HEAD` do not count. For approvals, rely on the host's review decision (and check review `commit_id` via `gh api` when a current-`HEAD` review is required).
- Run **3. Address CI & review feedback** for new CI failures and unresolved comments.
- Check `mergeStateStatus`: if `BEHIND` or `DIRTY`, rebase and push with `--force-with-lease` (`watch_pull_request` wakes on conflicts, not behind).
- Fixes prompted by CI or review count against a budget of **3 fix rounds**. Past that, stop and hand back.

## 5. Hand back

When checks and automated reviews are green on the latest `HEAD`, when blocked, or when only the user can answer a question or approve:

- Call `unwatch_pull_request` (unless a caller such as `full-send` is continuing to merge).
- Report the PR URL, current `HEAD` SHA, checks and reviews state, fixes applied, and any remaining blocker or human approval needed.

---

Adapted from Theo Browne's skills and Mikael Siidorow's `systems` under the [MIT license](LICENSE).
