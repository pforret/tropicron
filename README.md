# tropicron

A self-modifiable agent scheduling system for Claude Code.

tropicron is a file-based cron scheduler that runs Claude Code sessions on a schedule. It's called every minute by the OS crontab, matches cron expressions in job definition files, and launches Claude (or shell commands) accordingly.

## Why tropicron

**Zero tokens when idle** — All scheduling logic runs in pure bash. Cron matching, precheck diffing, and singleton detection happen without invoking the LLM. Claude is only called when a job actually fires *and* has something to do. A precheck that finds no changes costs zero tokens.

**Jobs are just Markdown files** — Each job is a readable `.md` file with YAML frontmatter for scheduling and a prompt body. You can add, edit, or delete jobs with any text editor, `git`, or the `/tropicron` Claude Code skill. An LLM can manage its own job schedule by writing `.md` files — no API, no database, no config format to learn.

## Quick start

```bash
# 1. Install the crontab entry
bin/tropicron.sh install

# 2. Create your first job
bin/tropicron.sh add examples/health-check.md

# 3. List jobs
bin/tropicron.sh list

# 4. Test a job (dry-run)
bin/tropicron.sh test health-check
```

## Directory structure

```
tropicron/
├── bin/
│   ├── tropicron.sh       # Main scheduler script
│   ├── cli-changed.sh     # Precheck: detect new CLI output
│   └── url-changed.sh     # Precheck: detect URL content changes
├── examples/              # Example job definitions
│   ├── daily-summary.md
│   ├── health-check.md
│   ├── scheduler-ping.md
│   └── url-monitor.md
├── jobs/                  # Active job definitions (*.md)
├── skills/
│   ├── tropicron/         # Claude Code /tropicron skill
│   └── tropicron-memory/  # Memory system documentation
└── README.md
```

## How it works

1. OS crontab calls `tropicron.sh run` every minute
2. The script parses `.md` files in `jobs/`, matches 5-field cron expressions
3. When a job matches, it either:
   - Executes a shell command (`run:` field) — no LLM tokens used
   - Invokes `claude -p` with the job's markdown prompt
4. Per-job memory files persist context across runs (`memory: true`)
5. Precheck scripts skip the LLM call when there's nothing new to process

## Job file format

Job files are Markdown with YAML frontmatter:

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

### Frontmatter fields

| Field | Default | Description |
|-------|---------|-------------|
| `cron` | *(required)* | 5-field cron expression |
| `enabled` | `true` | Set `false` to pause |
| `timeout` | `300` | Max seconds per run |
| `singleton` | `false` | Skip if previous run still active |
| `continue` | `false` | Resume last Claude session |
| `memory` | `false` | Load/save `<job>.memory.md` |
| `sandbox` | `false` | Use `--sandbox` (restricted permissions) |
| `model` | — | Override Claude model |
| `max_turns` | — | Limit agentic turns |
| `allowedTools` | — | Restrict tool access |
| `workdir` | — | Working directory override |
| `precheck` | — | Bash command; skip LLM if exit 0 + no stdout |
| `run` | — | Shell-only job (no LLM invocation) |
| `notify_on_failure` | — | Command to run on failure |
| `notify_on_success` | — | Command to run on success |

## Precheck helpers

### cli-changed.sh

Runs any CLI command, caches the output, and only reports new lines since the last check. Perfect for polling inboxes, notification feeds, or log files without wasting LLM tokens.

```bash
bin/cli-changed.sh mail-unread "notmuch search tag:unread | head -50"
bin/cli-changed.sh gh-notifications "gh api notifications --jq '.[].subject.title'"
```

### url-changed.sh

Fetches a URL, converts HTML/JSON to text, caches it, and reports diffs on change.

```bash
bin/url-changed.sh "https://docs.example.com/changelog"
```

## Commands

| Command | Description |
|---------|-------------|
| `tropicron.sh run` | Check schedule and execute matching jobs |
| `tropicron.sh list` | Show all jobs with status |
| `tropicron.sh add <file>` | Add a job file |
| `tropicron.sh remove <name>` | Remove a job |
| `tropicron.sh enable <name>` | Enable a paused job |
| `tropicron.sh disable <name>` | Disable a job |
| `tropicron.sh history [name]` | Show execution history |
| `tropicron.sh test <name>` | Dry-run a job |
| `tropicron.sh install` | Set up the crontab entry |
| `tropicron.sh uninstall` | Remove the crontab entry |
| `tropicron.sh check` | Verify dependencies and config |

## Logging

All job execution is logged to `logs/jobs/<job-name>/YYYY-MM-DD_HHMM.log`. The last line of each log contains exit status and duration:

```
---EXIT:0 DURATION:42s---
---EXIT:TIMEOUT DURATION:300s---
---EXIT:1 DURATION:5s---
```

Logs older than 30 days are automatically cleaned up. The main scheduler log is at `$LOG_DIR/tropicron.<date>.log`.

## Claude Code skill

Copy `skills/tropicron/` and `skills/tropicron-memory/` into your project's `.claude/skills/` to enable the `/tropicron` slash command for interactive job management.

## Safety

Every job file **must** include a "Safety guardrails" section defining what the job is NOT allowed to do. Jobs run non-interactively with `--dangerously-skip-permissions` (or `--sandbox` if `sandbox: true`). The scheduler will self-terminate if about to perform a dangerous action not covered by guardrails.

## Requirements

- Bash 4+
- `claude` CLI (Claude Code)
- `awk`, `timeout`, `crontab`
- Optional: `lynx` or `pandoc` (for url-changed.sh HTML conversion)
- Optional: `jq` (for url-changed.sh JSON formatting)

## License

MIT
