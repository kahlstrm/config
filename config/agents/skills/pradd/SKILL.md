---
name: pradd
description: Address PR review comments interactively
---

Address CI failures and review comments from the current branch's PR: $ARGUMENTS
If we're working with stacked PRs and no explicit arguments are given above, run this against the parts of the stack that aren't merged.

## CI

1. Fetch the PR number using `gh pr view --json number`
2. Check CI status using `gh pr checks {pr_number}` and collect any failing checks
3. If there are failing checks, investigate and fix them alongside review-comment work:
   - For each failing check, fetch logs using `gh run view {run_id} --log-failed`
   - Investigate the root cause and fix it
   - Inform the user of each fix
4. Report CI status. If checks are running or awaiting maintainer approval, report what remains pending and continue with review comments and other independent work. Do not wait for CI before fetching or addressing comments.

## Review comments

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

## Verification

After changes, run affected checks and recheck CI for the latest PR commit. Fix failing checks before reporting the PR ready to merge. If checks are pending or require approval, report that status; completing review fixes does not mean the PR is ready to merge.
