# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is tropicron

A file-based cron scheduler that runs Claude Code sessions on a schedule. Called every minute by OS crontab, it matches cron expressions in job definition `.md` files and launches `claude -p` (or shell commands) accordingly. Part of the Agentix ecosystem, split from TropicClaw.

## Commands

```bash
# Scheduler
bin/tropicron.sh run              # Check schedule, execute matching jobs
bin/tropicron.sh list             # Show all jobs with status
bin/tropicron.sh test <name>      # Dry-run a job
bin/tropicron.sh install          # Set up crontab entry
bin/tropicron.sh check            # Verify dependencies

# Job management
bin/tropicron.sh add <file.md>    # Add a job
bin/tropicron.sh remove <name>    # Remove a job
bin/tropicron.sh enable <name>    # Enable a job
bin/tropicron.sh disable <name>   # Disable a job
bin/tropicron.sh history [name]   # Show execution history

# Validation
bash -n bin/tropicron.sh          # Syntax check
shellcheck bin/tropicron.sh       # Lint
```

## Architecture

**tropicron.sh** is a bashew-based script (uses `IO:debug`, `Str:trim`, `Option:config()` patterns). The bashew framework functions are embedded in the lower portion of the script.

### Execution flow (every minute)
1. `do_run` → iterates `.md` files in `jobs/`
2. `parse_frontmatter()` extracts YAML frontmatter into `JOB_*` variables
3. `get_matching_jobs()` uses a single awk call to match all cron expressions against current time (supports ranges, steps, day-name aliases)
4. `acquire_lock()` / `release_lock()` implement file-based singleton locking in `locks/`
5. `execute_job()` builds the prompt (memory + job body + precheck output) and spawns `claude -p` in background with timeout

### Two job types
- **LLM jobs**: prompt from `.md` body is passed to `claude -p` (default)
- **Shell jobs**: `run:` field executes a command directly, no LLM tokens used

### Precheck system
Before invoking the LLM, an optional `precheck:` command runs. If it exits 0 with empty stdout, the job is skipped (saving tokens). Two helpers:
- `cli-changed.sh <name> <cmd>` — caches CLI output, reports only new lines
- `url-changed.sh <url>` — fetches URL, converts to text, reports diffs

### Per-job memory
When `memory: true`, a `<job>.memory.md` sibling file is prepended to the prompt and Claude is instructed to update it. Memory files are gitignored.

### Adding new verbs
In `Option:config()`, add verb to the choice line, then add a `case` block in `Script:main()`.

## Job file format

Markdown with YAML frontmatter. Key fields: `cron` (required), `enabled`, `timeout`, `singleton`, `continue`, `memory`, `sandbox`, `model`, `precheck`, `run`. Every job must include a "Safety guardrails" section. See `examples/` for templates.

## Runtime directories (gitignored)

- `logs/jobs/<name>/` — per-job execution logs (`YYYY-MM-DD_HHMM.log`)
- `locks/` — PID-based lock files for singleton jobs
- `jobs/*.memory.md` — per-job persistent memory
- `~/.cache/tropicron/` — precheck caches (cli-changed, url-changed)

## Requirements

Bash 4+, `claude` CLI, `awk`, `timeout`, `crontab`. Optional: `lynx`/`pandoc` (HTML conversion), `jq` (JSON formatting).
