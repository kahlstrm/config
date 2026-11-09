---
name: sol-loop
description: Use when the user says "sol loop", or when a rule requires a Sol review before a pull request.
---

# sol-loop

This is a workflow for making your code changes more correct before (or
sometimes after) filing a pull request. tl;dr - use OpenAI's GPT Sol to review
your code in a loop: review, fix, re-review until the review is clean.

Make the most minimal possible changes to appease the Sol reviewers. Be careful
of scope creep and don't be scared to push back.

The procedure (sections 1, 2, 4-6) is the same everywhere. Only how you reach
Sol changes; section 3 lists the backends.

## Budget

- Default: 3 rounds total. Round 1 is full. Later rounds check only
  changed code and open findings.
- Extend to 5 only for security, permissions, auth, data loss, or
  state/concurrency, while a blocker or should stays open with evidence. Or when
  the user asks.
- Stop early if a round returns only nits. Declined nits and comment,
  doc, or format-only fixes need no new round.
- One reviewer only. Sol must not start subagents, threads, or reviewers.
- Keep a ledger: id, severity, outcome, usage if returned. Never guess it.

## 1. Scope

Run `git status --short`. Do not stash, discard, or include unrelated
changes. Limit review to the change paths if they separate cleanly.
Otherwise stop and ask.

Find the base after `git fetch origin`:

- PR: `gh pr view <n> --json baseRefName,headRefOid`. Check out the branch
  only if clean. Confirm `HEAD` is the PR head, or ahead only by this
  change. Base: `git merge-base HEAD origin/<baseRefName>`.
- Local: `git merge-base HEAD origin/<default-branch>`. No remote: a base
  the user names, or `HEAD` for uncommitted changes only.

The change is base to working tree in those paths, with untracked files.
Use one diff command all rounds. State intent and out-of-scope in 1-2
sentences. Run covering checks. Do not send code this change breaks. Note
missing or pre-failing checks in the brief.

## 2. Brief

Round 1 brief. Reviewers get no history, so it must stand alone. `<diff>`
is how the backend's reviewer reads the change (section 3).

```
Review only. Do not edit, commit, push, comment on PRs, or start subagents or threads.
Repo: <repo> Base: <sha> Intent: <intent> Out of scope: <scope> Checks: <results>
See: <diff>
Read surrounding code. Find bugs, broken callers, mismatch with intent.
Skip style unless it hides a bug. Hold to the smallest change. Flag code,
tests, or guards the intent does not need. Other paths, rare cases, small
perf, extra compat: nits.
blocker = intended case wrong. should = real bug callers will hit, in intent. nit = rest.
Reply:
VERDICT: APPROVE or CHANGES
S1 [blocker|should|nit] <file>:<line> <claim>. Fix: <suggestion> (stable ids)
```

Do not edit scoped files while review runs. Wait for the reply. Do not poll
or start a second reviewer. Timeout, error, or no reply is not approval. On
failure, stop the reviewer, verify it stopped, and restart with the ledger.

## 3. Reach Sol

Use the first backend this environment has. Pick the latest Sol unless the
user named a version. Record provider, model, and effort only if exposed. If
no backend runs Sol, report the blocker. Never substitute another model.

### T3

Call `orchestrator_capabilities`; if T3 tools are not listed, try that one
call directly. Do not hardcode a model ID. Use `delegate_task` every round
(`role: "review"`, `mode: "async"`), effort in `target.options.reasoningEffort`.
Save `taskId`. New `clientRequestId` per round. `childThreadId` is storage,
not the next target. Do not use `t3_thread_send`, `create_threads`, or
`t3_thread_launch` for review. The child shares this machine, so `<diff>` is
`git diff <base> [-- <paths>]; git status --short (read untracked)` with the
absolute repo path.

### Amp

Start one review thread with `create_thread`: `agent_mode` the newest Sol
model it lists (today `openai/gpt-6.1-sol`), `intent: "independent-review"`,
default orb executor and project. It is the only thread this skill creates.

The reviewer's orb has a fresh checkout of the default branch, not your
working tree. Each round, write the whole base-to-working-tree change to a
patch with a scratch index, so your own index stays untouched:

```sh
(d="$(git rev-parse --absolute-git-dir)/sol-loop" && mkdir -p "$d" && export GIT_INDEX_FILE="$d/index" && git read-tree HEAD && git add -A -- <paths> && git diff --cached --binary <base> -- <paths> > "$d/round-<n>.patch")
```

Omit `-- <paths>` when the whole tree is in scope. The base must be on
origin. `<repo>` is the GitHub repository, and `<diff>` is:

```
Fetch the change with amp.download_thread_file from thread <this thread ID>,
path <absolute patch path>. Then: git fetch origin <base> && git checkout
--detach <base> && git apply --index <patch> && git commit -qm round-<n>.
This local commit in your own checkout is the one commit allowed; never
push it. Read the change with git show HEAD. If the fetch
or apply fails, reply with the error.
When done, call send_thread_message to <this thread ID> with only the reply
below. That message is your review. Do not run sol-loop or create threads.
```

Then end your turn; the review arrives as a message from that thread. Do
not also call `wait_for_threads`. Later rounds go to the same thread with
`send_thread_message`, a new patch, and: "Check out the base again, apply
this patch, commit it, and diff it against the last round's commit for the
change since last round." To stop a reviewer, send it a message to stop.

### Native subagent

Outside T3 and Amp, use a native Sol subagent and keep its ID. In Claude
Code, use a custom subagent only if it is set up to run Sol. `<diff>` is as
in T3.

## 4. Answer findings

Check each finding and severity yourself. Another path, rare case, or
small cost is a nit, whatever label it came with.

- Agree: smallest fix. Prefer delete or narrow over new lock, cache,
  helper, or option. Fix the case that happened. Add one focused test
  that fails without the fix, if intent needs it.
- Disagree: say why, with evidence (file:line, test, output).
- Out of scope or nit: decline in one line. List as follow-up.

Update the ledger. Re-run checks and `git diff --shortstat <base>`. If
review grew the diff, cut first. Do not agree just to end the loop.

## 5. Next round

Start one only if budget remains and a blocker or should is open, behavior code
changed, or approval does not cover the current behavior diff. Use the
backend's next-round route (a fresh `delegate_task` in T3, the same thread in
Amp, the saved ID for a native subagent). Send the round 1 brief, the ledger
(`fixed:` / `disagree:` / `declined:` + evidence), the same base diff, and the
change since last round. Tell Sol: open ids and changed code only. Mark each
old id `resolved` or `still open: <reason>`.

## 6. Stop and ship

Agreed: APPROVE on the current behavior diff, no blocker or should open,
no concern of your own. Stuck: an item stays disputed after two replies,
or budget ends. Show both sides in 2-3 lines each. The user decides.
Budget end is not approval.

Do not push during the loop. Push after agreement only if the user asked
to push, ship, or update the PR. If you push to a PR, add above the model
blurb:

`Reviewed with sol-loop: <N> rounds with <model>. Sol verdict: approved`.

Add `on <effort>` only if verified.

Report: backend, rounds, model, what Sol changed, diff size before/after,
fixed and declined findings with reasons, usage if exposed (else say not),
pushed or not.
