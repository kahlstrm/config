---
name: agents-md-review
description: "Review which rules in config/AGENTS.md and the VM instructions.md still change agent behaviour, using the AGENTS.md lab in tools/agents-md-lab, and propose removing or rewriting the rest. Use for /agents-md-review or when asked to re-test or prune the agent instructions."
disable-model-invocation: true
---

# AGENTS.md review

Follow "Reviewing the instructions" in `tools/agents-md-lab/README.md`. Read
`tools/agents-md-lab/journal/` first: the latest entry lists the retired rules,
the rules kept despite no measured effect, and the open questions to revisit.

- Trials draw on the shared Claude subscription. Present the plan, trial
  count, and start time, and get approval before running more than a smoke
  test. Schedule sweeps overnight with a user `systemd-run` timer.
- Read failing transcripts before trusting a verdict. Fix a grader or
  scenario that scores the wrong thing, and say which results it affected.
- Keep security boundaries whatever their verdict.
- Record the review as a new entry in `tools/agents-md-lab/journal/`, with
  run metadata, both reports, decisions, and open questions, in the same PR
  as the instruction changes.

**Reply:** the rules to retire, keep, or rewrite, each with its numbers, and
what the next review should check.
