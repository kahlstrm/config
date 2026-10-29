"""Aggregate trial grades into per-rule compliance rates and verdicts."""

import json
from collections import defaultdict
from dataclasses import dataclass
from math import comb
from pathlib import Path


@dataclass(frozen=True)
class Rate:
    passed: int
    failed: int
    skipped: int

    @property
    def graded(self):
        return self.passed + self.failed

    @property
    def ratio(self):
        return self.passed / self.graded if self.graded else None

    def __str__(self):
        cell = f"{self.passed}/{self.graded}" if self.graded else "–"
        return cell + (f" ({self.skipped} n/a)" if self.skipped else "")


def significance(full, ablated):
    """One-sided Fisher exact p-value that the rule raises compliance."""
    passed, total = full.passed + ablated.passed, full.graded + ablated.graded
    return sum(
        comb(passed, k) * comb(total - passed, full.graded - k)
        for k in range(full.passed, min(passed, full.graded) + 1)
    ) / comb(total, full.graded)


def verdict(full, ablated, alpha=0.05):
    if not full.graded or not ablated.graded:
        return "no data"
    if significance(full, ablated) < alpha:
        return "effective" if full.ratio >= 0.8 else "partial"
    if full.ratio < 0.5:
        return "ineffective"
    if ablated.ratio >= 0.8:
        return "redundant"
    return "inconclusive"


def rates(results: Path):
    counts = defaultdict(lambda: defaultdict(lambda: [0, 0, 0]))
    for path in sorted(results.glob("**/grade.json")):
        trial = json.loads(path.read_text())
        if trial.get("error"):
            continue
        for rule, grade in trial["grades"].items():
            counts[rule][trial["variant"]][{True: 0, False: 1, None: 2}[grade]] += 1
    return {
        rule: {variant: Rate(*count) for variant, count in variants.items()}
        for rule, variants in counts.items()
    }


def markdown(results: Path):
    empty = Rate(0, 0, 0)
    rows = [
        (rule, variants.get("full", empty), variants.get(f"minus-{rule}", empty), variants.get("none", empty))
        for rule, variants in sorted(rates(results).items())
    ]
    return "\n".join(
        [
            "| Rule | Full | Without rule | No prompt | p | Verdict |",
            "| --- | --- | --- | --- | --- | --- |",
            *(
                f"| {rule} | {full} | {ablated} | {none} | {pvalue(full, ablated)} | {verdict(full, ablated)} |"
                for rule, full, ablated, none in rows
            ),
        ]
    )


def pvalue(full, ablated):
    return f"{significance(full, ablated):.3f}" if full.graded and ablated.graded else "–"


def comparison(current: Path, candidate: Path):
    """Whether the candidate run's full instructions comply less often than the current run's."""
    empty = Rate(0, 0, 0)
    before, after = rates(current), rates(candidate)
    rows = [
        (rule, before.get(rule, {}).get("full", empty), after.get(rule, {}).get("full", empty))
        for rule in sorted(before.keys() | after.keys())
    ]
    return "\n".join(
        [
            "| Rule | Current | Candidate | p | Verdict |",
            "| --- | --- | --- | --- | --- |",
            *(f"| {rule} | {old} | {new} | {pvalue(old, new)} | {change(old, new)} |" for rule, old, new in rows),
        ]
    )


def change(current, candidate, alpha=0.05):
    if not current.graded or not candidate.graded:
        return "no data"
    return "regressed" if significance(current, candidate) < alpha else "held"
