# AGENTS.md lab

Measures whether each instruction in [`config/AGENTS.md`](../../config/AGENTS.md)
and the agent VM's [`instructions.md`](../../modules/agents/environment/instructions.md)
changes agent behaviour, so instructions that no longer help can be removed or
rewritten.

## Rules

[`catalogue.py`](catalogue.py) lists every instruction as a rule with its exact
text and how it is measured:

- `script`: a trial graded from the transcript, repository, or sandbox call log
- `judge`: a trial graded by an LLM judge against a written criterion
- `claim`: a factual statement checked against the running VM by `claims.py`
- `untested`: no safe or meaningful trial exists; the rule records why

The test suite fails when instruction text is not covered by exactly one rule,
or when a `script` or `judge` rule has no scenario. Editing either instruction
file therefore requires updating the catalogue. Rules removed from the
instructions move to `RETIRED`, so their scenarios keep grading the behaviour
under the remaining instructions.

## Trials

A scenario prepares a Git repository from a pinned snapshot of one of the
owner's repositories or from inline files, and gives a task in which one or more
rules have a natural chance to matter. Scenario modules live in `scenarios/`;
`scenarios/kit.py` documents the options.

Each scenario runs under several prompt variants:

- `full`: the complete instructions
- `minus-<rule>`: the instructions with that rule's text removed
- `none` (with `--baseline`): no instructions

The report compares compliance under `full` and `minus-<rule>` with a one-sided
Fisher exact test:

| Verdict | Meaning | Action |
| --- | --- | --- |
| effective | the rule significantly raises compliance, which reaches 80% | keep |
| partial | the rule significantly raises compliance, which stays below 80% | strengthen the wording |
| redundant | no significant effect; at least 80% compliance without the rule | candidate for removal |
| ineffective | below 50% compliance even with the rule | rewrite or remove |
| inconclusive | none of the above | run more repeats |

A verdict is only as good as its scenario: "redundant" means the model behaved
well without the rule in these tasks. Read failing transcripts before acting.

Compare the "No prompt" column too. A rule that is redundant on its own while
compliance drops without any instructions overlaps with other rules; removing
it together with those rules may still change behaviour. The reverse also
happens: a rule can be needed only because other instructions push the agent
the other way.

## Isolation and sandbox

Each trial runs `claude --print --setting-sources project --strict-mcp-config`
in a fresh directory under `/tmp`. The variant is written as `CLAUDE.md` in the
parent of the trial repository, which Claude Code loads like the global file.
User settings, `~/.claude/CLAUDE.md`, user MCP servers, and instruction files in
the home directory are not loaded. Instruction files tracked by a snapshot
repository are hidden from its worktree.

Trials run with permissions bypassed, so side effects stay local:

- `origin` is a local bare repository, and the system Git configuration with
  its credential helper is disabled
- `gh`, `agent-deploy`, and `agent-store-repair`, plus any CLI a scenario
  names, are stand-ins ([`shim.py`](shim.py)) that log calls and return
  canned output
- issue trackers are fake MCP servers ([`fake_mcp.py`](fake_mcp.py))

This prevents accidental effects; it is not a security boundary.

Trials use the operator's Claude sign-in and count against its usage limits.
The judge uses Opus with tools disabled.

## Usage

Run from this directory:

```sh
./lab.py list                                   # scenarios, and rules without one
./lab.py run --repeat 5 --baseline              # all scenarios
./lab.py run --rule tldr --repeat 10            # only ablate one rule
./lab.py run --out results/<run> --repeat 5     # resume or extend a run
./lab.py report results/<run>
./claims.py                                     # check the VM's factual claims
```

To test removing several rules together, run the full instructions without them
and compare the result with a run of the current instructions:

```sh
./lab.py run --full-only --remove comments --remove jq --repeat 5 --out results/<pruned>
./lab.py compare results/<current> results/<pruned>
```

A rule marked `regressed` complies less often once the others are removed.

Results stay in `results/`, which Git ignores. Each trial directory holds the
transcript, the diff, sandbox calls, and `grade.json` with judge reasons.
Snapshot repositories are mirrored under `~/.cache/agents-md-lab/mirrors`.

## Reviewing the instructions

Repeat a review after a new model generation, a harness update, or when the
instructions have grown. Start from the latest entry in [`journal/`](journal/):

1. Run `./claims.py` and correct any factual claim that no longer holds.
2. Sweep every rule: `./lab.py run --repeat 5 --baseline --out results/sweep-<date>`.
   Copy both instruction files aside first and pass them with `--instructions`,
   so later steps measure the same text even if `main` changes meanwhile.
3. Read the report and the failing transcripts. Removal candidates are
   `redundant` rules whose trap is strong, and `ineffective` rules nobody wants
   to rewrite. Keep security boundaries regardless of their verdict.
4. Remove the candidates together with `--full-only --remove <rule>...` and the
   same `--instructions`, then `./lab.py compare` it with the sweep.
5. If nothing regressed, delete the rules from the instructions, move them to
   `RETIRED` in `catalogue.py`, and record the review in `journal/` with the run
   metadata, both reports, the decisions, and open questions. Open one PR with
   all three changes.
6. In later sweeps, check the `Full` column of retired rules; restore a rule
   whose behaviour has dropped.

A full sweep is about 600 trials and spans several subscription usage windows.
Runs stop at a usage limit and resume with the same `--out`, so schedule them
outside working hours, for example:

```sh
systemd-run --user --on-calendar "<date> 00:00" --working-directory "$PWD" \
  --setenv=PATH="$PATH" --setenv=HOME="$HOME" \
  --property=StandardOutput=append:$HOME/.cache/agents-md-lab/<run>.log \
  "$(command -v python3)" lab.py run --repeat 5 --baseline --out results/<run>
```

Repeat the timer on following nights until the log reports no unrun trials.

## Adding a rule or scenario

1. When an instruction changes, update its rule text in `catalogue.py`.
2. Add a scenario to a module in `scenarios/` that lists the rule and grades
   it, preferably from tool calls, sandbox calls, or repository state.
3. Smoke it with `./lab.py run --scenario <id> --repeat 1` and read the
   transcripts to confirm the grader scores what happened.
4. Run `python3 -m unittest discover -s . -p "test_*.py"`. CI runs the same
   suite as the `agents-md-lab` flake check.
