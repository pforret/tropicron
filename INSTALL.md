# Installing tropicron as a Claude Code plugin

## One-liner install

```bash
claude --add-marketplace "https://raw.githubusercontent.com/pforret/tropicron/main/marketplace.json"
```

This adds the tropicron marketplace to Claude Code. The `/tropicron` skill becomes available in all your projects.

## Manual install

If you prefer to install the skills directly into a single project:

```bash
cd your-project/
mkdir -p .claude/skills
cp -r /path/to/tropicron/skills/tropicron .claude/skills/
cp -r /path/to/tropicron/skills/tropicron-memory .claude/skills/
```

## Verify installation

In a Claude Code session, type:

```
/tropicron list
```

This should list all scheduled jobs (or an empty list if none exist yet).

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI installed
- Bash 4+
- `awk`, `timeout`, `crontab`
- Optional: `lynx` or `pandoc` (for URL content conversion)
- Optional: `jq` (for JSON formatting)

## Setting up the scheduler

After installing the plugin, set up the crontab entry that runs tropicron every minute:

```bash
bin/tropicron.sh install
```

## Uninstall

Remove the marketplace source:

```bash
claude --remove-marketplace "https://raw.githubusercontent.com/pforret/tropicron/main/marketplace.json"
```

Or for manual installs, delete the skill directories:

```bash
rm -rf .claude/skills/tropicron .claude/skills/tropicron-memory
```
