---
cron: "*/5 * * * *"
enabled: true
timeout: 10
description: "Scheduler heartbeat — write timestamp (no LLM)"
singleton: true
run: "date +%s > /tmp/tropicron-ping.txt"
---
