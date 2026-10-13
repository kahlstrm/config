---
name: pradd
description: Address PR review comments and CI failures
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
10. Validate each review finding against the code and intended behavior. Address clear bugs and regressions within the requested scope without asking the user to select them.
11. Ask when a finding requires a product decision, changes access or isolation, materially expands scope, or has multiple approaches with meaningful tradeoffs.
12. Explain findings you reject and why. Preserve existing approval requirements for external communication and deployment.
13. Implement validated fixes and inform the user of progress.

## Verification

After changes, run affected checks and recheck CI for the latest PR commit. Fix failing checks before reporting the PR ready to merge. If checks are pending or require approval, report that status; completing review fixes does not mean the PR is ready to merge.
