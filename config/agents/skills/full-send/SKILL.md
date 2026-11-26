---
name: full-send
description: Watch a PR until green and approved, merge it, and monitor post-merge CI/deploy workflows until they finish. Use when the user says "full send", "watch and merge", or "merge and watch CI".
---

# Full send

Take the current work or PR end to end: finish, prove, watch until green and approved, merge, and monitor post-merge CI/deploy runs.

## Grant & repo precedence

- Follow [full-stop](../full-stop/SKILL.md) (its grant, proof, review, ready, and asking rules), except its no-merge rule does not apply: invoking `full-send` authorizes merging once the gate passes and monitoring post-merge CI for this PR without asking again.
- If the repository defines its own ship procedure (for example `.agents/ship.md`), finish and prove the change per `full-stop`, then follow the repository's ship procedure from branch/PR setup through merge (marking any open draft PR ready before merging if the ship procedure does not), and continue here at **3. Watch post-merge CI**.

## 1. PR, readiness check & watch

- Complete `full-stop` steps 1–5 (finish, prove, open/update PR via `babysit-pr`, `sol-loop`, rebase and mark ready if draft).
- Evaluate the **2. Merge gate** immediately before starting a watch. If the PR is already ready to merge, go straight to merging (do not call `watch_pull_request` on an already-ready PR, because existing green checks and approvals are treated as baseline and will not wake).
- Otherwise, run `babysit-pr` with `watch_pull_request(until: "merged")` so T3 wakes the thread on checks, reviews, approvals, and conflicts until the gate passes. Apply `full-stop`'s proof and `sol-loop` re-review rules to any CI fixes, review fixes, or conflict resolutions pushed during babysitting, then re-verify **2. Merge gate** on the resulting `HEAD` before merging.

## 2. Merge gate

Before watching and on each wake, check the latest `HEAD` (`pull_request_read` with `include: ["checks", "threads", "comments"]`):

- All required checks have passed on the current `HEAD` (none pending or failing).
- The host's current review decision satisfies required approvals, no reviewer is requesting changes, and no review threads remain unresolved. If the repo requires approval on the exact current `HEAD`, verify review `commit_id` via `gh api`.
- The PR is mergeable (`git fetch`; if new base commits conflict with or touch the PR's files, rebase, push with `--force-with-lease`, and keep watching).

When the gate passes:

- Choose the merge method documented by the repo, else the only method allowed by the repo (`gh api repos/{owner}/{repo}` → `allow_*_merge`), else `squash`. Do not use admin bypass unless repo docs explicitly allow it.
- Merge with `pull_request_merge` passing both `expectedHeadSha` (`headSha`) and `method` (the selected method). Outside T3, pass the selected method (`--squash`, `--merge`, or `--rebase`) to `gh pr merge <number> --<method> --match-head-commit <sha>`.
- If the repo uses a merge queue or auto-merge, wait until GitHub reports the PR merged and capture the merge commit SHA.

## 3. Watch post-merge CI

- Get the merge commit SHA from the merge result (or `gh pr view <number> --json mergeCommit --jq '.mergeCommit.oid'`).
- On the initial check and every subsequent wake, re-list all runs on that commit (deploy and downstream workflows included):
  `GH_PAGER=cat gh run list --commit <mergeSha> --limit 100 --json databaseId,name,status,conclusion,url`
- Treat any run whose `status` is not `completed` (including `queued`, `in_progress`, and `waiting`) as still active.
- **In T3 (`schedule_task` available):** Always schedule a recurring `schedule_task` (`type: "interval"`, `everyMs: 120000`, `bindToCurrentThread: true`) after merge — even if the first listing is empty or shows only completed runs — so delayed or chained deploy workflows are discovered. Keep it running while any run has `status != "completed"`; once every discovered run is `completed`, keep one final 2-minute follow-up check and call `delete_scheduled_task` only when that check confirms no new or active runs.
- **Outside T3:** Watch every active run with `gh run watch <id> --exit-status`, then wait a bounded discovery window (60–120 seconds) and re-list. If any new or active runs appear, watch them through completion and repeat the discovery check until a re-list shows no new or active runs.
- If any post-merge or deploy workflow fails, inspect its failed logs (`gh run view <id> --log-failed`), report the failure and likely cause, and **stop and ask before reverting**.

## 4. Report

Include `full-stop`'s report (PR URL, proof, review rounds, routine decisions), plus the merge commit SHA and the result (with links) of every post-merge workflow run.

---

Adapted from Theo Browne's skills and Mikael Siidorow's `systems` under the [MIT license](LICENSE).
