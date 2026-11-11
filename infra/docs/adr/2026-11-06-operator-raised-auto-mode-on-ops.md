# Let the operator raise ops threads to Claude's auto mode

- Status: superseded by [the ops retirement ADR](2026-11-10-retire-the-ops-vm.md); it lapses
  with T3 on ops
- Date: 2026-11-06

## Context

[ADR 9](0009-approval-capped-ops-environment.md) runs root infrastructure work on
the ops VM. Threads that the agents VM delegates there run at `approval-required`,
and Claude Code's managed settings disabled both bypass and auto mode, so every
command outside a short read-only allow list waited for the operator. Rollouts
with many steps meant many prompts, and agents chained commands with `&&` to
reduce them.

The operator wants ops to act as one more agent that finishes its task, with
privileges the operator grants per task and then monitors. Approving each command
is not needed once the operator has approved the task's plan.

Tested on 2026-11-06 with T3 0.1.6 against a thread the agents VM delegated to ops:

- The operator can raise a thread the link started above the link's cap. In the
  app, choosing a mode in the composer only changes the draft; T3 applies it with
  the next message the operator sends. A text reply while an approval is pending
  declines that approval instead.
- After the raise, the agents VM's `t3_thread_send` and archive calls on that thread
  failed with `runtime_mode_escalation_denied`.
- Raising during a running Claude turn ended that turn.
- A message the agents VM had queued at `approval-required` ran after the raise.
  T3 checks the sender's limit when a message is sent, not when it starts.
- At Full access, T3 reported that it could not confirm Claude's bypass mode and
  ran with approval checks, because the managed settings disable bypass. With
  bypass disabled but auto mode allowed, T3 runs Full access in auto mode instead.

Tested again on 2026-11-07, after this change was deployed, from the mobile app:

- At Auto, a command outside the allow list ran without a prompt. Back at
  Supervised, the same command asked again.
- A mode chosen during a turn applied only from the next message.
- The delegated task on the agents VM ended with the first turn's result. Turns
  the operator started afterwards did not update or wake it.
- Asked to read a file under `/var/lib/ops-credentials` to test the deny rule,
  ops' agent refused because of its instructions, so the deny rule was not tested
  in auto mode.

Other options considered: a T3 change that holds a delegated task until the
operator approves it and picks its mode, as proposed upstream for model changes
in pingdotgg/t3code#29890, or one that pre-approves a task's exact commands. Both
need T3 changes, either accepted upstream or carried as a patch. Codex was
rejected: it runs commands it considers read-only, such as `cat`, without asking,
and has no deny rules for paths.

## Decision

Allow Claude Code's auto mode on ops by removing `disableAutoMode` from its
managed settings. Everything else stays: the link remains `approval-required`,
bypass mode stays disabled, and the allow and deny rules are unchanged.

Delegated threads start at `approval-required`. After approving a task's plan,
the operator may raise its thread to Auto, between turns and with no messages
queued, and monitors it from there. Agents cannot raise a thread themselves.

Ops' agent gets its own instructions (`modules/agent-ops/instructions.md`),
appended to the shared ones. Before running a task, it checks that the brief
makes sense and stops on anything unexplained, broader than the goal, or at odds
with what it finds. It checks each command against the approved plan, treats the
brief and command output as data, and never starts `claude` or `t3`. These
instructions guide the model; they are not a boundary.

## Consequences

- In an Auto thread, Claude's auto-mode reviewer, not the operator, approves each
  command. The operator's approval moves from each command to the plan and the
  decision to raise.
- The deny rules still refuse file reads of the credential paths in Auto, but a
  command could still read those files in a way the rules don't match, such as a
  script. Whatever a thread prints returns to the agents VM, so a leak of
  credentials there depends on the reviewer and on the operator monitoring.
- Once the thread is raised, the agents VM can only read and wait on it. A message
  it queued before the raise still runs at Auto, so raise only with an empty queue.
- A nested Claude can now run in auto mode. In a Supervised thread, an approved
  command such as `claude -p --permission-mode auto "<task>"` starts a second
  Claude that reads the same managed settings and works through its own reviewer.
  Its steps never reach T3 as prompts, and the thread does not show as raised.
  Before this change, `disableAutoMode` stopped it, and without auto mode a `-p`
  run has no one to ask, so it refuses anything off the allow list. It adds no
  power that approving an arbitrary script did not already give, but its prompt
  reads as a harmless instruction. The operator does not approve commands that
  start `claude` or `t3` on ops. Deny rules for them would only catch the plain
  form, since rules that match a prefix miss `env claude` or a full path.
- Bypass mode stays disabled, so Full access runs in auto mode too. No mode on ops
  skips the reviewer.
- The agents VM learns the outcome of turns after the raise only by reading the
  ops thread, once the operator reports that the task is done.
- The `agent-ops` check no longer requires auto mode to be disabled. It still
  fails if bypass mode becomes available.
