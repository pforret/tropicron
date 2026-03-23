---
name: tropicron
description: Manage scheduled tropicron jobs (list, add, remove, enable, disable, history, test)
disable-model-invocation: false
allowed-tools: Bash(*/tropicron.sh *), Read, Write, Edit, Glob
argument-hint: "[list|add|remove|enable|disable|history|test] [job-name]"
---

## Tropicron — Scheduled Job Manager

Job files live in the `jobs/` directory relative to the tropicron installation. Each is a `.md` with YAML frontmatter (cron, enabled, timeout, etc.) and a prompt body.

### Available commands

- `/tropicron list` — show all jobs with status
- `/tropicron add <name>` — create a new job interactively (ask user for cron, prompt, options)
- `/tropicron remove <name>` — delete a job
- `/tropicron enable <name>` / `/tropicron disable <name>` — toggle a job
- `/tropicron history <name>` — show recent execution logs
- `/tropicron test <name>` — dry-run, show what would execute

### When invoked without arguments

Run `tropicron.sh list` and show the results.

### When adding a new job

1. Ask for: description, cron schedule, timeout, safety guardrails
2. Create the `.md` file in the jobs directory with proper frontmatter
3. Every job MUST include a "Safety guardrails" section
4. Run `tropicron.sh test <name>` to verify

### Frontmatter fields

| Field | Default | Description |
|-------|---------|-------------|
| `cron` | (required) | 5-field cron expression |
| `enabled` | true | Set false to pause |
| `timeout` | 300 | Max seconds |
| `singleton` | false | Skip if previous run still active |
| `continue` | false | Resume last session |
| `memory` | false | Load/save `<job>.memory.md` |
| `sandbox` | false | Use `--sandbox` (restricted) |
| `model` | — | Override model |
| `notify_on_failure` | — | CLI command on failure |
| `notify_on_success` | — | CLI command on success |
| `precheck` | — | Bash command; skip LLM if exit 0 + no stdout |
| `run` | — | Shell-only job (no LLM invocation) |

### Example job file

```markdown
---
cron: "0 9 * * MON-FRI"
enabled: true
timeout: 300
singleton: true
memory: true
description: "Daily task summary"
---

# Daily Summary

Summarize today's priorities.

## Safety guardrails
- Do NOT delete files
- Do NOT run destructive commands
```
