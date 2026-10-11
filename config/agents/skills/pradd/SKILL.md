---
name: pradd
description: Address PR review comments interactively
---

Address CI failures and review comments from the current branch's PR: $ARGUMENTS
If we're working with stacked PRs and no explicit arguments are given above, run this against the parts of the stack that aren't merged.

## Phase 1: CI

1. Fetch the PR number using `gh pr view --json number`
2. Check CI status using `gh pr checks {pr_number}` and collect any failing checks
3. If there are failing checks, fix them all before moving to Phase 2:
   - For each failing check, fetch logs using `gh run view {run_id} --log-failed`
   - Investigate the root cause and fix it
   - Inform the user of each fix
4. If all checks pass, inform the user and move to Phase 2

## Phase 2: Review comments

Do NOT start this phase until Phase 1 is complete.

5. Fetch review comments using `gh pr view {pr_number} --json reviews,comments`
6. From that response, extract unresolved comments
7. Only if inline diff comments are missing, fetch them with `gh api repos/{owner}/{repo}/pulls/{pr_number}/comments`
8. For each unresolved comment, extract: author, body, file path, line number
9. Summarize each comment in one line describing what change is requested
10. Let the user choose which comments to address:
    - In Claude, use the AskUserQuestion tool with `multiSelect: true`.
    - Format options as:
      - Label: Brief summary (~50 chars max)
      - Description: Author and additional context
    - In agents without AskUserQuestion, present a numbered list and ask the user to reply with selected numbers.
11. For each selected comment:
    - Navigate to the relevant file and line
    - Implement the requested change
    - Inform the user of progress
