# 2026-10 clean-code probe

In the [first sweep](2026-10.md), Claude Code guarded the database call in
`paivabot-stats-command` 5/5 with the full instructions and 5/5 with none, but
only 2/5 with `clean-code` removed. This probe asked whether another rule
suppresses error handling that `clean-code` then restores.

| | Probe |
| --- | --- |
| Lab revision | `b9c11ab` |
| Instructions | `config/AGENTS.md` and `instructions.md` at `b9c11ab`, after the rules retired in [2026-10.md](2026-10.md) |
| Harness and model | Claude Code 2.1.312, `claude-opus-5-5` |
| Trials | 30: `paivabot-stats-command`, `--full-only`, 10 per run |
| Cost (API-equivalent) | $10.54 |

## Results

| Run | Removed | clean-code | p against A |
| --- | --- | --- | --- |
| A | `clean-code` | 1/10 | |
| B | `clean-code`, `functional-style` | 7/10 | 0.010 |
| C | `clean-code`, `dry` | 5/10 | 0.070 |

One-sided Fisher exact tests. In every trial the grade matched whether the
`stats` handler wrapped the database call in `try`/`except`. No transcript
cited a rule for leaving it out.

Together with the first sweep, the instructions without `clean-code` reach
3/15 against 5/5 without any instructions (p = 0.004), so the earlier 2/5 was
not noise.

## Findings

- `functional-style` suppresses error handling: removing it restores most of
  the default behaviour. The likely trigger is its call for "logically
  condensed blocks"; failing trials write a short handler around a query
  helper and leave failures unhandled.
- `dry` may contribute; 5/10 is not significant at ten repeats.
- `clean-code` is what currently offsets this for Claude Code, which complied
  5/5 with the full instructions in both the sweep and the pruned run. Codex fails 0/5 in every variant, so its
  failure comes from the model, not from another rule.

## Recommendations

- Make `functional-style` exempt error handling, for example by ending it with
  "Condensed code still handles errors at I/O boundaries."
- Make `clean-code` concrete enough for Codex: "Handle failures of I/O such as
  database, network, file and subprocess calls by reporting or logging them,
  rather than letting them crash the caller or vanish. Don't wrap code that
  cannot fail."
- Measure both rewordings with Claude Code and Codex before changing
  `config/AGENTS.md`.
