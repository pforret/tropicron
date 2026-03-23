---
cron: "0 9 * * MON-FRI"
enabled: false
timeout: 300
singleton: true
memory: true
description: "Daily task summary and priorities"
---

# Daily Summary

Review the current state of work and summarize:

1. What was accomplished yesterday
2. What's planned for today
3. Any blockers or things that need attention

Write a concise summary.

## Safety guardrails
- Do NOT delete any files
- Do NOT push code or create PRs
- Do NOT modify any source code
- Only read files and write the summary
