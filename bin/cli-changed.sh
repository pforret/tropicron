#!/usr/bin/env bash
### cli-changed.sh — Run any CLI command, detect new output since last check
###
### Usage: cli-changed.sh <name> <command...>
###
###   name      — unique identifier for caching (e.g. "signal-inbox", "mail-unread")
###   command   — the shell command to run (rest of args, or quoted string)
###
### Exit 0 + empty stdout → no new output (precheck: skip LLM)
### Exit 0 + stdout        → new output found (precheck: trigger LLM)
### Exit 1 + stdout        → command failed (precheck: trigger LLM with error)
###
### Stdout format when new output found:
###   ## New output from: <name>
###   ### New lines (since last check)
###   <only the new lines>
###   ### Full current output
###   <complete output, truncated to 500 lines>
###
### The script caches the output and on subsequent runs only reports lines
### that are NEW (not seen in the previous run). This works well for:
###   - Email: `notmuch search --output=summary tag:unread`
###   - Signal: `signal-cli -u +1234 receive --json`
###   - Telegram: `telegram-cli -W -e 'history <peer> 10'`
###   - Slack: `slack-term` or MCP-based channel reads
###   - RSS: `rss2email run --no-send --stdout`
###   - Git: `git log --oneline origin/main..HEAD`
###   - Logs: `journalctl -u myservice --since '5 min ago'`
###
### Examples:
###   cli-changed.sh mail-unread "notmuch search tag:unread | head -50"
###   cli-changed.sh signal-msgs "signal-cli -u +1234 receive --json 2>/dev/null"
###   cli-changed.sh gh-notifications "gh api notifications --jq '.[].subject.title'"
###   cli-changed.sh syslog-errors "journalctl -p err --since '15 min ago' --no-pager"

set -euo pipefail

NAME="${1:?Usage: cli-changed.sh <name> <command...>}"
shift
CMD="$*"
[[ -z "$CMD" ]] && { echo "Usage: cli-changed.sh <name> <command...>"; exit 1; }

CACHE_DIR="${CLI_CHANGED_CACHE:-${HOME}/.cache/tropicron/cli-changed}"
cache_file="${CACHE_DIR}/${NAME}.txt"
mkdir -p "$CACHE_DIR"

# --- Run the command ------------------------------------------------------
tmp_output=$(mktemp)
trap 'rm -f "$tmp_output"' EXIT

cmd_exit=0
eval "$CMD" > "$tmp_output" 2>&1 || cmd_exit=$?

# Normalize trailing whitespace
sed -i 's/[[:space:]]*$//' "$tmp_output"

# --- Handle command failure -----------------------------------------------
if [[ $cmd_exit -ne 0 ]]; then
  echo "## Command failed: $NAME"
  echo ""
  echo "Exit code: $cmd_exit"
  echo "Command: \`$CMD\`"
  echo ""
  echo "### Error output"
  echo ""
  cat "$tmp_output"
  exit 1
fi

# --- Empty output = nothing to report ------------------------------------
if [[ ! -s "$tmp_output" ]]; then
  # Command succeeded with no output — nothing new
  # Clear cache so next time there IS output, we report it
  rm -f "$cache_file"
  exit 0
fi

# --- First run (no cache) — report everything as new ----------------------
if [[ ! -f "$cache_file" ]]; then
  cp "$tmp_output" "$cache_file"
  echo "## New output from: $NAME (first check)"
  echo ""
  echo "### Current output"
  echo ""
  head -500 "$tmp_output"
  if [[ $(wc -l < "$tmp_output") -gt 500 ]]; then
    echo ""
    echo "[... truncated at 500 lines ...]"
  fi
  exit 0
fi

# --- Diff against cache to find only NEW lines ----------------------------
new_lines=$(mktemp)
# Lines in current output that weren't in the cached output
comm -13 <(sort "$cache_file") <(sort "$tmp_output") > "$new_lines" || true

if [[ ! -s "$new_lines" ]]; then
  # No new lines — update cache (in case lines were removed) but don't trigger
  cp "$tmp_output" "$cache_file"
  rm -f "$new_lines"
  exit 0
fi

new_count=$(wc -l < "$new_lines")

echo "## New output from: $NAME ($new_count new lines)"
echo ""
echo "### New lines (since last check)"
echo ""
cat "$new_lines"
echo ""
echo "### Full current output"
echo ""
head -500 "$tmp_output"
if [[ $(wc -l < "$tmp_output") -gt 500 ]]; then
  echo ""
  echo "[... truncated at 500 lines ...]"
fi

# Update cache for next run
cp "$tmp_output" "$cache_file"
rm -f "$new_lines"
exit 0
