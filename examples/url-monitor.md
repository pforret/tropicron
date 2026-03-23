---
cron: "0 */6 * * *"
enabled: false
timeout: 120
sandbox: true
singleton: true
memory: true
description: "Monitor a URL for changes"
precheck: "bin/url-changed.sh https://docs.anthropic.com/en/docs/claude-code/overview"
---

# URL Change Monitor

A URL you are monitoring has changed. Review the precheck output which contains the diff and current content.

Summarize what changed and whether it's significant. Update your memory file with:
- Date of change
- Brief summary of what changed
- Whether it seems important

## Safety guardrails
- Do NOT modify any files except your memory file
- Do NOT run any shell commands
- Do NOT access any network resources beyond what the precheck provides
- Only analyze and summarize the changes
