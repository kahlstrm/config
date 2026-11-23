---
name: pradd
description: Address PR review comments and CI failures
---

Address CI failures and review comments from the current branch's PR: $ARGUMENTS
If we're working with stacked PRs and no explicit arguments are given above, run this against the parts of the stack that aren't merged.

## CI

When T3 PR tools (`pull_request_read`, `ci_logs`) are available, prefer them over `gh`.

1. Fetch the PR state and checks (`pull_request_read` with `sections: ["summary", "checks"]`, or `gh pr view --json number` + `gh pr checks {pr_number}`) and collect any failing checks
2. If there are failing checks, investigate and fix them alongside review-comment work:
   - For each failing check, fetch logs (`ci_logs` or `gh run view {run_id} --log-failed`)
   - Investigate the root cause and fix it
   - Inform the user of each fix
3. Report CI status. If checks are running or awaiting maintainer approval, report what remains pending and continue with review comments and other independent work. Do not wait for CI before fetching or addressing comments.

## Review comments

4. Fetch review comments and threads (`pull_request_read` with `sections: ["conversation"]`, or `gh pr view {pr_number} --json reviews,comments`)
5. From that response, extract unresolved comments
6. Outside T3, if inline diff comments are missing, fetch them with `gh api repos/{owner}/{repo}/pulls/{pr_number}/comments`
7. For each unresolved comment, extract: author, body, file path, line number
8. Summarize each comment in one line describing what change is requested
9. Validate each review finding against the code and intended behavior. Address clear bugs and regressions within the requested scope without asking the user to select them.
10. Ask when a finding requires a product decision, changes access or isolation, materially expands scope, or has multiple approaches with meaningful tradeoffs.
11. Explain findings you reject and why. Preserve existing approval requirements for external communication and deployment.
12. Implement validated fixes and inform the user of progress.

## Verification

After changes, run affected checks and push. Fix failing checks before reporting the PR ready to merge. If checks are pending or require approval, report that status without polling (let a calling watch skill handle the wait); completing review fixes does not mean the PR is ready to merge.
