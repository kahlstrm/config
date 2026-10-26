#!/usr/bin/env python3
"""Measure which AGENTS.md rules change agent behaviour."""

import argparse
import json
import shutil
import subprocess
import threading
import sys
import traceback
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path

sys.dont_write_bytecode = True

import catalogue
import prompt
import report
import repos
import runner
from scenarios import SCENARIOS

HERE = Path(__file__).parent
REPOSITORY = HERE.parent.parent


def ablate(instructions, rule):
    for removed in (rule, *catalogue.RULES[rule].with_):
        instructions = prompt.without(instructions, catalogue.RULES[removed].text)
    return instructions


def variants(scenario, instructions, rules, baseline):
    yield "full", instructions
    for rule in scenario.rules:
        if rule in rules and prompt.span(catalogue.RULES[rule].text).search(instructions):
            yield f"minus-{rule}", ablate(instructions, rule)
    if baseline:
        yield "none", ""


def plan(arguments, instructions):
    rules = set(arguments.rule or catalogue.RULES)
    chosen = [
        SCENARIOS[name]
        for name in arguments.scenario or SCENARIOS
        if rules & set(SCENARIOS[name].rules)
    ]
    return [
        (scenario, variant, text, arguments.out / scenario.id / variant / str(repeat))
        for scenario in chosen
        for variant, text in variants(scenario, instructions, rules, arguments.baseline)
        for repeat in range(arguments.repeat)
    ]


LIMITED = threading.Event()


def trial(item, arguments):
    """Run one trial unless it already has a clean result or usage limits were hit."""
    scenario, variant, text, path = item
    if (path / "grade.json").exists():
        record = json.loads((path / "grade.json").read_text())
        if not record["error"]:
            return record
    if LIMITED.is_set():
        return None
    shutil.rmtree(path, ignore_errors=True)
    try:
        record = runner.run_trial(scenario, variant, text, path, arguments.model, arguments.budget)
    except Exception:
        path.mkdir(parents=True, exist_ok=True)
        (path / "failure.txt").write_text(traceback.format_exc())
        record = {"scenario": scenario.id, "variant": variant, "cost": None, "error": "trial crashed", "grades": {}}
    if runner.usage_limited(record["error"]):
        LIMITED.set()
    print(f"{scenario.id} {variant} {path.name}: {record['grades']} {record['error'] or ''}", flush=True)
    return record


def run(arguments):
    arguments.instructions = arguments.instructions or [str(REPOSITORY / path) for path in catalogue.SOURCES]
    instructions = "\n\n".join(Path(path).read_text() for path in arguments.instructions)
    arguments.out = arguments.out or HERE / "results" / datetime.now().strftime("%Y%m%d-%H%M%S")
    trials = plan(arguments, instructions)
    runner.preflight()
    for source in {scenario.source for scenario, *_ in trials if scenario.source}:
        repos.mirror(source)
    arguments.out.mkdir(parents=True, exist_ok=True)
    (arguments.out / "run.json").write_text(
        json.dumps(
            {
                "revision": subprocess.check_output(["git", "-C", str(REPOSITORY), "rev-parse", "HEAD"], text=True).strip(),
                "instructions": arguments.instructions,
                "model": arguments.model,
                "repeat": arguments.repeat,
            },
            indent=2,
        )
        + "\n"
    )
    print(f"{len(trials)} trials in {arguments.out}", flush=True)
    with ThreadPoolExecutor(arguments.jobs) as pool:
        records = [record for record in pool.map(lambda item: trial(item, arguments), trials) if record]
    failed = sum(bool(record["error"]) for record in records)
    print(f"\n{len(records)} trials, {failed} failed, ${sum(r.get('cost') or 0 for r in records):.2f}")
    if LIMITED.is_set():
        print(f"Stopped at a usage limit; {len(trials) - len(records)} trials not run. Re-run with --out {arguments.out}.")
    print()
    summarise(argparse.Namespace(results=arguments.out))


def summarise(arguments):
    table = report.markdown(arguments.results)
    (arguments.results / "report.md").write_text(table + "\n")
    print(table)


def list_scenarios(_):
    for scenario in SCENARIOS.values():
        print(f"{scenario.id}: {', '.join(scenario.rules)}")
    covered = {rule for scenario in SCENARIOS.values() for rule in scenario.rules}
    for rule in catalogue.RULES.values():
        if rule.id not in covered:
            print(f"  {rule.id}: {rule.note or 'checked by claims.py'}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(required=True)

    run_parser = commands.add_parser("run", help="run trials")
    run_parser.add_argument("--scenario", action="append", choices=SCENARIOS)
    run_parser.add_argument("--rule", action="append", choices=catalogue.RULES, help="only ablate these rules")
    run_parser.add_argument("--repeat", type=int, default=3)
    run_parser.add_argument("--jobs", type=int, default=4)
    run_parser.add_argument("--model")
    run_parser.add_argument("--budget", type=float, default=3.0, help="USD cap per trial")
    run_parser.add_argument("--baseline", action="store_true", help="also run without any instructions")
    run_parser.add_argument(
        "--instructions",
        action="append",
        help="instruction files, joined in order (default: global and VM instructions)",
    )
    run_parser.add_argument("--out", type=Path, help="results directory; existing trials are kept")
    run_parser.set_defaults(handler=run)

    report_parser = commands.add_parser("report", help="summarise a results directory")
    report_parser.add_argument("results", type=Path)
    report_parser.set_defaults(handler=summarise)

    commands.add_parser("list", help="list scenarios and rules without one").set_defaults(handler=list_scenarios)

    arguments = parser.parse_args()
    arguments.handler(arguments)


if __name__ == "__main__":
    main()
