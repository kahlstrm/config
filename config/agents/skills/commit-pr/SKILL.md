---
name: commit-pr
description: Create a commit and pull request using the PR template
---

Create a commit and pull request for changes: $ARGUMENTS

## Steps

0. Run repository specific checks, lint, tests that are relateed to the changes.

1. **Gather context**
   - Run `git status` to see staged and unstaged changes
   - Run `git diff` to see the actual changes
   - Run `git log --oneline -5` to see recent commit style

2. **Prepare branch first**
   - Check current branch with `git branch --show-current`
   - If on main/master:
     - Ask user if they want to create a ticket (Linear issue) first
     - If yes, create the ticket and use its identifier for the branch name
     - If no, auto-generate a descriptive branch name based on the changes
     - Create branch with `git checkout -b <branch>`

3. **Review before submitting**
   - Determine the actual PR target branch; do not assume `main` or a particular remote.
   - Prefer the dedicated Codex reviewer when available: use `codex review --base <target-ref>` for committed branch changes and `codex review --uncommitted` when staged, unstaged, or untracked changes also need review.
   - If Codex is missing, unsupported, or cannot run because of authentication, quota, or service availability, use an independent reviewer subagent when supported. Ask it to review the same changes for correctness, security, regressions, and missing test coverage, without editing files.
   - If neither reviewer can run, review the diff yourself and tell the user why independent review was unavailable. Continue the submission workflow; do not claim independent review passed or bypass required repository checks.
   - Validate findings, fix confirmed issues, and rerun affected checks. Review any resulting changes before submitting, using the same fallback order. Treat reported code defects as findings to address, not reviewer unavailability.
   - Report which review method ran and any remaining limitations when presenting the PR text for approval under repository instructions. Local review does not authorize posting a GitHub review trigger or other external communication.

4. **Stage and commit**
   - Stage the files relevant to changes made in the current session with `git add <files>`
   - Write a concise one-line commit message following Conventional Commits
   - Use format: `type: description` (e.g., `feat:`, `fix:`, `chore:`, `docs:`)
   - Commit with `git commit -m "message"`

5. **Push and create pull request**
   - Push branch to remote with `git push -u origin <branch>`
   - Check if `.github/PULL_REQUEST_TEMPLATE.md` (or `.github/pull_request_template.md`) exists in the repository (from the repository root!).
   - If template exists, read it and fill in based on the changes:
     - Replace placeholders with actual content from the commits
   - If no template, create a basic PR body with summary and changes list
   - Create PR with `gh pr create --title "PR title" --body "body content"`
   - Return the PR URL to the user
