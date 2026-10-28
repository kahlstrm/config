# Agentic Code Instructions

Please take the following instruction into mind when working.
These are not final instructions and the user can overrule them for each unit of work

## Coding instructions

### Tool Use

- When parsing json, use `jq`.
- When using AWS CLI, use the --profile to select the AWS SSO profile. To list available profiles, use `aws configure list-profiles`

### File edits and approvals

Prefer the dedicated file-editing tool provided by the environment.
Let its permission and approval controls handle the request.

Do not infer that an operation is unavailable solely from a tool's
parameter schema. Unless explicitly prohibited, try the normal tool
and use its actual response to determine the next step.

Do not substitute shell commands or scripts solely because you assume
the editing tool cannot request approval. Respect denials and use the
environment's supported approval process.

### Workflow practices

- If infrastructure-as-code configuration exists, always use it for infrastructure changes instead of other methods, including for temporary resources and experiments.
- Propose incremental edits that are easily comprehensible with separation of logic; if adding two or more logical concepts to the same file, add them separately.
- For code changes, prefer writing a meaningful failing test first, then implement the change and verify it passes. A meaningful test checks behavior, not what the code already states; if the only possible test would restate the code, skip it. Only commit tests that run in CI.
- Check recent commits to see the commit convention used. Prefer use of the Conventional Commit Specification while writing commit messages.
- Write ONLY concise oneliners as commit messages without a description.
- When creating an issue to Linear/Jira, put it to backlog instead of triage immediately.
- In repositories the user owns (in the agent environment, those under the manifest's `github.owner`), writing and updating PR titles and descriptions, replying to review comments, resolving review threads and commanding bots are part of the task; do not ask for text approval. Keep the text concise, factual and within scope.
- Elsewhere (upstream PRs, issues, comments, mailing lists and chat), present the exact text and obtain the user's explicit approval before posting it. A prefilled PR link that the user submits counts as that approval.
- Carry an authorized task through: do the next in-scope step instead of ending the turn with an offer such as "Want me to…?". Stop to ask only for product or design choices, scope changes, irreversible or costly actions, or access changes, and then ask one question with a recommended option.
- Write repository documentation for the durable post-merge system and normal operating workflow. Keep PR state, rollout checkpoints, and one-time migration notes in the PR description unless future operators still need them.
- End with a one-line TL;DR whenever the reply answers a question, reports a check, or explains something longer than a few lines: `**TL;DR:** <verdict or answer first>, <one caveat if any>.`

### Coding practices

- Write clean, readable code with proper error handling
- If possible, follow a "loosely" declarative and functional style; using programming language idiomatic patterns and conventions,
  try to write logically condensed blocks by limiting scope by using higher-level functions, separating code blocks to functions or using other language features.
- Follow existing codebase practices and conventions for consistency, while abiding by other instructions described here.
- Document ONLY complex and/or obscure logic with comments; self-explanatory code shouldn't need comments. Usually a variable or function name should be enough documentation.
- Follow DRY principle: extract repeated code into functions/modules after 3+ uses, or 2+ uses for large identical blocks.
- Before writing utility functions, consider searching for existing functionality in the codebase first for code reuse.

- Whenever there is some kind of verification in place, addressing it by fixing it is the only way to go forward. Skipping or disabling verification steps is NOT ALLOWED. There are no "unrelated" errors, and every error should be fixed.

### Debugging practices

- When debugging a problem, first investigate to find the actual root cause before jumping to conclusions or proposing fixes.
- Instead of telling the user to run diagnostic commands, try to run them yourself.
