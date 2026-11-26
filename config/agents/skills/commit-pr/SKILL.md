---
name: commit-pr
description: Review, commit, and open a pull request, then stop without watching CI. Use when the user says "commit-pr", "commit and PR", "open a PR", or "submit a PR".
---

# Commit and PR

Create a commit and pull request for the current changes: $ARGUMENTS

- **Pre-submit review:** Run relevant repository checks, lint, and tests first. Then run `sol-loop` against the actual PR target branch with a budget of 1 round (up to 3 if round 1 finds a blocker or the change touches security, auth, data loss, or state/concurrency) at `medium` reasoning effort (`high` for those risky changes). If repo rules require Sol and Sol cannot run, do not substitute another reviewer — follow the repository's Sol-unavailability rule; otherwise fall back to `codex review` → read-only reviewer subagent → self-review (stating why independent review was unavailable). Re-run affected checks after any review fixes.
- **Commit & open:** Branch off the default branch if needed, stage and commit the reviewed changes, and push (`git push -u origin <branch>`) when the PR tool does not push for you. Fill `.github/PULL_REQUEST_TEMPLATE.md` (or `.github/pull_request_template.md`) at the repo root if present, explicitly call out non-obvious test assertion or subtle behavioral shifts, and note which review ran. Open with `pull_request_create` (or `gh pr create`), without calling `watch_pull_request` (watching belongs to `babysit-pr`, `full-stop`, and `full-send`). When invoked directly, return the PR URL and stop; when invoked by another skill, return the PR URL so the caller can continue.
