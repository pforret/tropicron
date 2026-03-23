---
name: tropicron-memory
description: How tropicron per-job memory works
user-invocable: false
---

## Per-Job Memory

Each tropicron job can have a `<job>.memory.md` sibling file for persistent context.

- When `memory: true` in frontmatter, the memory file is prepended to the prompt
- Claude is instructed to update the memory file with important findings
- Memory files are gitignored (runtime state, not config)
- Keep memory files concise (<100 lines) — summarize, don't accumulate

### Memory file location

`<job>.memory.md` lives next to `<job>.md` in the jobs directory.

### What to store in memory

- Last-seen values, counters, dates
- Recurring patterns discovered across runs
- User preferences learned from feedback
- Errors to avoid on future runs
- State that should persist (e.g., "last email checked: 2026-02-25")
