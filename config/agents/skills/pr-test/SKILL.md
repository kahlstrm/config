---
name: pr-test
description: Test a PR with automated checks and manual verification, then report findings and coverage gaps
---

Test the PR: $ARGUMENTS
In a stack, "next PR" means the next unmerged layer, not the whole stack.

1. Read the PR description and diff. Record the head SHA and base.
2. Preserve local changes; use a worktree if the checkout is dirty. Follow the repository's setup guidance and confirm the running app serves the PR head.
3. Build a checklist from the PR's test instructions and the risks in the diff. Run relevant automated checks, then exercise risky paths manually, including failure and cached-data states. A green suite alone is not full coverage.
4. Test the environment as users reach it (HTTPS, real origin, auth). Investigate failures instead of silently switching protocol or origin; if you must fall back, state what it cannot cover.
5. Separate PR regressions from environment problems with evidence. Mark unresolved checks incomplete, never passed.
6. Reuse existing authorization within scope. Before an unapproved live mutation, prepare the exact target and payload, then ask.
7. Report bugs; fix them only when asked or required by repository instructions.
8. Stop services, close tabs and restore the checkout you changed.
9. Report findings, passed checks and gaps not covered as separate sections.
