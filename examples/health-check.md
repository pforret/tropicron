---
cron: "0 * * * *"
enabled: false
timeout: 60
description: "Simple health check — verify tropicron is working"
sandbox: true
singleton: true
---

# Health Check

This is a simple health check job. Confirm you are running by writing:

1. The current date and time
2. Your model name
3. "tropicron health check OK"

Do NOT perform any other actions.

## Safety guardrails
- Do NOT read, write, or modify any files
- Do NOT run any shell commands
- Do NOT access any network resources
- Only output the health check message above
