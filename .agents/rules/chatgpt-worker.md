# chatgpt-worker workspace rule

For substantive coding, debugging, implementation, refactoring, testing, or code-review requests in this workspace, use the installed chatgpt-worker workflow by default unless the user explicitly asks not to use it or asks for a simple direct answer that does not require repository changes.

Do not require the user to type /chatgpt-worker again after this rule has been installed.

Before starting worker execution:
- use the opened workspace/repository as project scope;
- ensure .chatgpt-worker.toml exists, running guided first-run configuration if needed;
- use the Git-backed task-branch communication protocol;
- keep the opened user workspace untouched by worker task branches/worktrees;
- validate the exact implementation commit using the configured local or remote execution environment.

If the user says phrases such as "don't use chatgpt-worker", "do this directly", or otherwise clearly opts out, respect that request for the current task.

After meaningful development/debugging work, review whether any durable lesson should be persisted:
- repository-specific durable conventions/traps -> .agents/rules/project-lessons.md;
- truly cross-project reusable engineering techniques/traps -> the global chatgpt-worker-learnings skill.
Do not persist one-off task details, secrets, credentials, temporary paths, transient failures, or unverified guesses.
