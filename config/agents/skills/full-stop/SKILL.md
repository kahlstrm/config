---
name: full-stop
description: Take the work end to end to a green PR ready for review, without merging. Use when the user says "full stop", even as a closing "Full stop."
---

# Full stop

The user is not watching; they read your final message later. Own the work from its current state to a ready, green PR, and make routine calls yourself.

## Grant & boundaries

Invoking `full-stop` grants, for this task only:

- pushing (`--force-with-lease` on the task's branch), marking the PR ready, and requesting the reviewers documented by the repo;
- running the verification methods Proof needs (tests, running the app, browser, simulators, screenshots). Repository testing rules and harness approval prompts still apply.

**Never merge, enable auto-merge, enter a merge queue, or push to the default branch.** If auto-merge is already enabled on the PR, turn it off (`gh pr merge --disable-auto`) and note that in the report.

## Steps

1. **Finish the change** with the smallest change that works. If on the default branch, branch first.
2. **Prove it** (see Proof).
3. **Open or update the PR:** open a PR via `babysit-pr` step **1. Open PR** if none exists (respecting any repo or global PR-text approval rule). If a PR already exists, handle existing comments via `babysit-pr` step **3. Address CI & review feedback**.
4. **Review & push:** if the PR already existed and `sol-loop` has not approved the current diff, run `sol-loop`. Commit and push all reviewed changes on the existing-PR path and confirm the remote PR `HEAD` matches local `HEAD`.
5. **Ready:** rebase onto the base branch if behind or conflicting (`git push --force-with-lease`), mark ready (`pull_request_update` with `ready: true`, or `gh pr ready`) if draft, and request the reviewers the repo's docs name.
6. **Bots & CI:** run `babysit-pr` until green on the latest `HEAD`. Prove each fix before pushing it. If CI fixes, review fixes, or conflict resolution change the behavior diff after `sol-loop` approved, follow `sol-loop`'s "Next round" rules before clearing the gate.
7. **Gate & report:** verify the Gate on the latest `HEAD` (reporting Sol approval only when it covers the final diff), then hand off (see Gate and Report).

Stay active through steps 1–7: ending a turn while work is still pending stops progress. In T3, `babysit-pr`'s watch wakes you.

## Proof

Evidence observed in this session, as direct as the change allows: reproduce the failure, fix it, and verify the reproduction passes; run the checks CI runs; add a focused failing test when the behavior lacks coverage; for UI or runtime changes, run the app and verify it directly. Green mocked tests alone do not prove user-facing behavior. If you cannot prove the change, ask.

## Gate

On the latest `HEAD`: proof covers every change, required checks are green, automated review bots have finished with each finding fixed or dismissed with a reason, no human review requests changes, and the branch is up to date and mergeable.

## Asking

Ask only when you cannot continue alone: you cannot prove the change, the gate cannot pass and you cannot fix it, the next step is outside the grant (production, deleting data, anything outside the repo, closing or force-pushing another PR), or the goal is ambiguous in a way that materially changes the result. Decide routine calls yourself and list them in the report.

Use the harness's question tool (`ask_question`, `AskUserQuestion`, `request_user_input`) with the PR link, the blocker, and options (recommended first). If no question tool is available or no answer arrives, take the safe path and lead your final message with the question.

## Report

Call `unwatch_pull_request` first (unless a caller such as `full-send` is continuing to merge). Then report: PR URL, final `HEAD` SHA, verdict (**ready**, **waiting on approval**, or **blocked** and why), proof, review rounds, and routine decisions made.

---

Adapted from Theo Browne's skills and Mikael Siidorow's `systems` under the [MIT license](LICENSE).
