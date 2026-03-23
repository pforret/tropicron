#!/usr/bin/env bash
### ==============================================================================
### tropicron — Self-Modifiable Agent Scheduling System
### Called every minute by crontab, decides fast whether to run any job,
### and if so, launches it by passing a <JOB>.md file to `claude -p`.
### ==============================================================================
###
### FOR LLMs: QUICK REFERENCE
### -------------------------
### ADDING NEW VERBS: In Option:config(), add verb to the choice line
###                   then add a case block in Script:main(): newverb) do_newverb ;;
###
### JOB FORMAT: .md files in jobs/ with YAML frontmatter:
###   cron: "0 9 * * MON-FRI"    (required)
###   enabled: true               (default: true)
###   timeout: 300                (default: 300)
###   singleton: false            (default: false — skip if previous still running)
###   continue: false             (default: false — use --continue to resume session)
###   memory: false               (default: false — load/save <job>.memory.md)
###   sandbox: false              (default: false — use --sandbox instead of --dangerously-skip-permissions)
###   model: sonnet               (optional)
###   max_turns: 10               (optional)
###   allowedTools: Read,Write    (optional)
###   workdir: /path              (optional)
###   notify_on_failure: "cmd"    (optional)
###   notify_on_success: "cmd"    (optional)
###   precheck: "bash command"    (optional — run before LLM; skip if exit 0 + no stdout)
###   run: "bash command"          (optional — run shell command directly, no LLM invocation)
###
### PRECHECK: The precheck field runs a bash command before invoking Claude.
###   If the command exits 0 with empty stdout, the job is skipped (no tokens).
###   If it exits non-zero or produces stdout, the output is prepended to the
###   prompt as "## Precheck output" so the LLM can act on it.
###   Helpers:
###     url-changed.sh <url>        — fetch URL, cache, output diff on change
###     cli-changed.sh <name> <cmd> — run any CLI, cache, output new lines only
### ==============================================================================

### Created by Peter Forret ( pforret ) on 2026-02-26
### Based on https://github.com/pforret/bashew 1.22.1
script_version="0.1.0"
readonly script_author="peter@forret.com"
readonly script_created="2026-02-26"
readonly run_as_root=-1
readonly script_description="Self-modifiable agent scheduling system for Claude Code"

function Option:config() {
  grep <<<"
flag|h|help|show usage
flag|Q|QUIET|no output
flag|V|VERBOSE|also show debug messages
flag|f|FORCE|do not ask for confirmation (always yes)
option|L|LOG_DIR|folder for log files|${TROPICRON_LOG_DIR:-$HOME/log/tropicron}
option|T|TMP_DIR|folder for temp files|/tmp/tropicron
option|J|JOB_DIR|folder for job definitions|${TROPICRON_JOB_DIR:-}
choice|1|action|action to perform|run,list,add,remove,enable,disable,history,test,install,uninstall,check,env
param|?|input|job name or file path
" -v -e '^#' -e '^\s*$'
}

#####################################################################
## Main script
#####################################################################

function Script:main() {
  IO:log "[$script_basename] $script_version started"

  # Default JOB_DIR to jobs/ subfolder of script location
  [[ -z "$JOB_DIR" ]] && JOB_DIR="$script_install_folder/jobs"

  case "${action,,}" in
  run)
    #TIP: use «$script_prefix run» to check schedule and execute matching jobs
    #TIP:> $script_prefix run
    do_run
    ;;
  list)
    #TIP: use «$script_prefix list» to show all jobs with status
    #TIP:> $script_prefix list
    do_list
    ;;
  add)
    #TIP: use «$script_prefix add <file.md>» to add a job file
    #TIP:> $script_prefix add myjob.md
    do_add "$input"
    ;;
  remove)
    #TIP: use «$script_prefix remove <name>» to remove a job
    #TIP:> $script_prefix remove myjob
    do_remove "$input"
    ;;
  enable)
    #TIP: use «$script_prefix enable <name>» to enable a paused job
    #TIP:> $script_prefix enable myjob
    do_enable "$input"
    ;;
  disable)
    #TIP: use «$script_prefix disable <name>» to disable a job without deleting
    #TIP:> $script_prefix disable myjob
    do_disable "$input"
    ;;
  history)
    #TIP: use «$script_prefix history [name]» to show execution history
    #TIP:> $script_prefix history myjob
    do_history "$input"
    ;;
  test)
    #TIP: use «$script_prefix test <name>» to dry-run a job (show what would execute)
    #TIP:> $script_prefix test myjob
    do_test "$input"
    ;;
  install)
    #TIP: use «$script_prefix install» to set up the crontab entry
    #TIP:> $script_prefix install
    do_install
    ;;
  uninstall)
    #TIP: use «$script_prefix uninstall» to remove the crontab entry
    #TIP:> $script_prefix uninstall
    do_uninstall
    ;;
  check | env)
    #TIP: use «$script_prefix check» to verify dependencies and config
    #TIP:> $script_prefix check
    Os:require "claude"
    Os:require "awk"
    Os:require "timeout"
    Script:check
    ;;
  *)
    IO:die "action [$action] not recognized"
    ;;
  esac
  IO:log "[$script_basename] ended after $SECONDS secs"
}

#####################################################################
## Helper functions
#####################################################################

### --- Frontmatter parsing ---

function parse_frontmatter() {
  # Parse YAML frontmatter from a job .md file
  # Sets JOB_* variables for each key found
  local file="$1"
  local in_frontmatter=0

  # Reset all JOB_ variables
  JOB_CRON=""
  JOB_ENABLED="true"
  JOB_TIMEOUT="300"
  JOB_DESCRIPTION=""
  JOB_MODEL=""
  JOB_ALLOWEDTOOLS=""
  JOB_WORKDIR=""
  JOB_MAX_TURNS=""
  JOB_APPEND_PROMPT=""
  JOB_SINGLETON="false"
  JOB_CONTINUE="false"
  JOB_MEMORY="false"
  JOB_SANDBOX="false"
  JOB_NOTIFY_ON_FAILURE=""
  JOB_NOTIFY_ON_SUCCESS=""
  JOB_PRECHECK=""
  JOB_RUN=""

  while IFS= read -r line; do
    if [[ "$line" == "---" ]]; then
      ((in_frontmatter++))
      [[ $in_frontmatter -ge 2 ]] && break
      continue
    fi
    if [[ $in_frontmatter -eq 1 ]]; then
      # Skip empty lines and comments
      [[ -z "$line" ]] && continue
      [[ "$line" == \#* ]] && continue
      local key value
      key="${line%%:*}"
      key="$(Str:trim "$key")"
      value="${line#*:}"
      value="$(Str:trim "$value")"
      # Strip surrounding quotes
      value="${value#\"}"
      value="${value%\"}"
      value="${value#\'}"
      value="${value%\'}"
      # Convert key to uppercase and set JOB_ variable
      local var_name="JOB_${key^^}"
      printf -v "$var_name" '%s' "$value"
    fi
  done <"$file"
}

function extract_prompt() {
  # Return everything after the second '---' line
  local file="$1"
  awk '/^---$/{n++; next} n>=2' "$file"
}

### --- Cron matching (awk-based, fast) ---

function get_matching_jobs() {
  # Collect enabled jobs and match cron expressions via single awk call
  # Outputs matching job names (one per line)
  local job_lines=""

  if [[ ! -d "$JOB_DIR" ]]; then
    IO:debug "No jobs directory: $JOB_DIR"
    return
  fi

  local has_jobs=0
  for job_file in "$JOB_DIR"/*.md; do
    [[ ! -f "$job_file" ]] && continue
    # Skip memory files
    [[ "$(basename "$job_file")" == *.memory.md ]] && continue
    has_jobs=1

    local cron_expr enabled
    cron_expr=$(awk '/^---$/{n++; next} n==1 && /^cron:/{gsub(/^cron: *"?|"? *$/,"",$0); print; exit}' "$job_file")
    enabled=$(awk '/^---$/{n++; next} n==1 && /^enabled:/{gsub(/^enabled: *|^ */,"",$0); print; exit}' "$job_file")
    [[ "${enabled:-true}" == "false" ]] && continue
    [[ -z "$cron_expr" ]] && continue
    job_lines+="$(basename "$job_file" .md)|${cron_expr}"$'\n'
  done

  [[ $has_jobs -eq 0 ]] && return
  [[ -z "$job_lines" ]] && return

  # Single awk call: match all cron expressions against current time
  echo "$job_lines" | awk -v now_min="$(date +%-M)" \
    -v now_hour="$(date +%-H)" \
    -v now_dom="$(date +%-d)" \
    -v now_month="$(date +%-m)" \
    -v now_dow="$(date +%-u)" \
    'BEGIN { FS="|"
    split("MON,TUE,WED,THU,FRI,SAT,SUN", dn, ",")
    for (i in dn) dow_map[dn[i]] = i
  }
  function field_match(pattern, value, fmin, fmax,    parts, i, lo, hi, step, rng, v) {
    if (pattern == "*") return 1
    step = 1
    if (index(pattern, "/")) {
      split(pattern, parts, "/")
      step = parts[2] + 0
      pattern = parts[1]
    }
    if (pattern == "*") {
      return ((value - fmin) % step == 0) ? 1 : 0
    }
    split(pattern, parts, ",")
    for (i in parts) {
      gsub(/ /, "", parts[i])
      if (toupper(parts[i]) in dow_map) parts[i] = dow_map[toupper(parts[i])]
      if (index(parts[i], "-")) {
        split(parts[i], rng, "-")
        lo = (toupper(rng[1]) in dow_map) ? dow_map[toupper(rng[1])] : rng[1] + 0
        hi = (toupper(rng[2]) in dow_map) ? dow_map[toupper(rng[2])] : rng[2] + 0
        for (v = lo; v <= hi; v += step) {
          if (v == value) return 1
        }
      } else {
        if (parts[i] + 0 == value) return 1
      }
    }
    return 0
  }
  /\|/ {
    job = $1; cron = $2
    split(cron, f, " ")
    if (field_match(f[1], now_min, 0, 59) &&
        field_match(f[2], now_hour, 0, 23) &&
        field_match(f[3], now_dom, 1, 31) &&
        field_match(f[4], now_month, 1, 12) &&
        field_match(f[5], now_dow, 1, 7)) {
      print job
    }
  }'
}

### --- Lock file mechanism ---

function acquire_lock() {
  local job_name="$1"
  local is_singleton="${2:-false}"
  local lock_dir="$script_install_folder/locks"
  local lock_file="${lock_dir}/${job_name}.lock"

  [[ ! -d "$lock_dir" ]] && mkdir -p "$lock_dir"

  if [[ -f "$lock_file" ]]; then
    local lock_pid lock_age
    lock_pid=$(cat "$lock_file" 2>/dev/null)

    # Get file modification time (cross-platform)
    local file_mtime
    if stat --version &>/dev/null; then
      file_mtime=$(stat -c %Y "$lock_file" 2>/dev/null)
    else
      file_mtime=$(stat -f %m "$lock_file" 2>/dev/null)
    fi
    lock_age=$(( $(date +%s) - file_mtime ))

    # Check if the locked process is still alive
    if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
      if [[ "$is_singleton" == "true" ]]; then
        IO:debug "Singleton job $job_name still running (pid=$lock_pid, ${lock_age}s), skipping"
        return 1
      else
        IO:debug "Job $job_name has overlapping run (pid=$lock_pid), proceeding anyway"
      fi
    else
      # Process is gone — stale lock
      IO:debug "Stale lock for $job_name (pid=$lock_pid gone, ${lock_age}s old), removing"
      rm -f "$lock_file"
    fi
  fi

  echo "$$" >"$lock_file"
  return 0
}

function release_lock() {
  local job_name="$1"
  local lock_dir="$script_install_folder/locks"
  rm -f "${lock_dir}/${job_name}.lock"
}

### --- Job execution ---

function execute_job() {
  local job_file="$1"
  local job_name
  job_name=$(basename "$job_file" .md)

  # If run: is set, execute shell command directly (no LLM)
  if [[ -n "$JOB_RUN" ]]; then
    local job_log_dir="${LOG_DIR}/jobs/${job_name}"
    [[ ! -d "$job_log_dir" ]] && mkdir -p "$job_log_dir"
    local log_file="${job_log_dir}/$(date +%Y-%m-%d_%H%M).log"
    local workdir="${JOB_WORKDIR:-$script_install_folder}"
    IO:log "Executing shell job: $job_name"
    (
      cd "$workdir" || exit 1
      eval "$JOB_RUN" >"$log_file" 2>&1
      local exit_code=$?
      echo "---EXIT:${exit_code}---" >>"$log_file"
      release_lock "$job_name"
    ) &
    return
  fi

  # Build prompt: memory (optional) + job body
  local prompt=""
  local memory_file="${JOB_DIR}/${job_name}.memory.md"

  if [[ "$JOB_MEMORY" == "true" ]]; then
    if [[ -f "$memory_file" ]]; then
      prompt="## Persistent Memory (from previous runs)"$'\n\n'
      prompt+="$(cat "$memory_file")"
      prompt+=$'\n\n---\n\n'
    else
      # Create empty memory file
      echo "# Memory: ${job_name}" >"$memory_file"
      echo "" >>"$memory_file"
      echo "No previous runs recorded yet." >>"$memory_file"
    fi
  fi
  prompt+="$(extract_prompt "$job_file")"

  # Append memory-update instruction if memory is enabled
  if [[ "$JOB_MEMORY" == "true" ]]; then
    prompt+=$'\n\n---\n## Memory instruction\n'
    prompt+="Update the file ${memory_file} with important findings, state, "
    prompt+="or decisions from this run that should persist for future runs. "
    prompt+="Keep it concise. Preserve useful info from previous runs."
  fi

  # Append date context if append_prompt is set
  if [[ -n "$JOB_APPEND_PROMPT" ]]; then
    prompt+=$'\n\n'"$JOB_APPEND_PROMPT"
  fi

  local job_log_dir="${LOG_DIR}/jobs/${job_name}"
  [[ ! -d "$job_log_dir" ]] && mkdir -p "$job_log_dir"
  # Cleanup old logs (older than 30 days)
  find "$job_log_dir" -name "*.log" -mtime +30 -delete 2>/dev/null || true
  local log_file="${job_log_dir}/$(date +%Y-%m-%d_%H%M).log"

  # Build claude invocation args
  local claude_args=()
  if [[ "$JOB_CONTINUE" == "true" ]]; then
    claude_args+=(--continue --print "$prompt")
  else
    claude_args+=(-p "$prompt")
  fi
  claude_args+=(--output-format text)

  if [[ "$JOB_SANDBOX" == "true" ]]; then
    claude_args+=(--sandbox)
  else
    claude_args+=(--dangerously-skip-permissions)
  fi

  # Optional flags
  [[ -n "$JOB_MODEL" ]] && claude_args+=(--model "$JOB_MODEL")
  [[ -n "$JOB_MAX_TURNS" ]] && claude_args+=(--max-turns "$JOB_MAX_TURNS")
  [[ -n "$JOB_ALLOWEDTOOLS" ]] && claude_args+=(--allowedTools "$JOB_ALLOWEDTOOLS")

  local workdir="${JOB_WORKDIR:-$script_install_folder}"

  IO:log "Executing job: $job_name (timeout=${JOB_TIMEOUT}s)"

  # Run in background subshell
  (
    cd "$workdir" || exit 1
    local start_time
    start_time=$(date +%s)
    timeout "$JOB_TIMEOUT" claude "${claude_args[@]}" >"$log_file" 2>&1
    local exit_code=$?
    local duration=$(( $(date +%s) - start_time ))

    if [[ $exit_code -eq 0 ]]; then
      echo "---EXIT:0 DURATION:${duration}s---" >>"$log_file"
      IO:log "Job $job_name completed successfully (${duration}s)"
      if [[ -n "$JOB_NOTIFY_ON_SUCCESS" ]]; then
        JOB_NAME="$job_name" eval "$JOB_NOTIFY_ON_SUCCESS" 2>/dev/null || true
      fi
    elif [[ $exit_code -eq 124 ]]; then
      echo "---EXIT:TIMEOUT DURATION:${duration}s---" >>"$log_file"
      IO:log "Job $job_name timed out after ${JOB_TIMEOUT}s"
      if [[ -n "$JOB_NOTIFY_ON_FAILURE" ]]; then
        JOB_NAME="$job_name" JOB_ERROR="timeout" eval "$JOB_NOTIFY_ON_FAILURE" 2>/dev/null || true
      fi
    else
      echo "---EXIT:${exit_code} DURATION:${duration}s---" >>"$log_file"
      IO:log "Job $job_name failed with exit code $exit_code (${duration}s)"
      if [[ -n "$JOB_NOTIFY_ON_FAILURE" ]]; then
        JOB_NAME="$job_name" JOB_ERROR="exit_${exit_code}" eval "$JOB_NOTIFY_ON_FAILURE" 2>/dev/null || true
      fi
    fi

    release_lock "$job_name"
  ) &
}

### --- Action implementations ---

function do_run() {
  # Core loop: called every minute by crontab
  Os:require "claude"
  Os:require "awk"

  local matching_jobs
  matching_jobs=$(get_matching_jobs)

  if [[ -z "$matching_jobs" ]]; then
    IO:debug "No matching jobs at $(date +%H:%M)"
    return 0
  fi

  while IFS= read -r job_name; do
    [[ -z "$job_name" ]] && continue
    local job_file="${JOB_DIR}/${job_name}.md"

    if [[ ! -f "$job_file" ]]; then
      IO:alert "Job file not found: $job_file"
      continue
    fi

    # Full frontmatter parse for this job
    parse_frontmatter "$job_file"

    # Singleton check
    if ! acquire_lock "$job_name" "$JOB_SINGLETON"; then
      continue
    fi

    # Precheck: run bash command, skip LLM if exit 0 and no stdout
    if [[ -n "$JOB_PRECHECK" ]]; then
      local precheck_output
      local precheck_exit
      precheck_output=$(cd "${JOB_WORKDIR:-$script_install_folder}" && eval "$JOB_PRECHECK" 2>&1) || true
      precheck_exit=$?
      if [[ $precheck_exit -eq 0 ]] && [[ -z "$precheck_output" ]]; then
        IO:debug "Precheck passed clean for $job_name — skipping LLM call"
        release_lock "$job_name"
        continue
      fi
      # Precheck produced output or failed — prepend to prompt so LLM sees it
      IO:log "Precheck for $job_name triggered (exit=$precheck_exit, output=${#precheck_output} bytes)"
      JOB_APPEND_PROMPT="## Precheck output (exit code: $precheck_exit)"$'\n\n'"$precheck_output"$'\n\n'"${JOB_APPEND_PROMPT}"
    fi

    execute_job "$job_file"
    IO:log "Launched job: $job_name"
  done <<<"$matching_jobs"
}

function do_list() {
  if [[ ! -d "$JOB_DIR" ]]; then
    IO:print "No jobs directory found at $JOB_DIR"
    return 0
  fi

  local has_jobs=0
  # Print header
  printf "%-20s %-18s %-8s %-22s %s\n" "Job" "Cron" "Enabled" "Last Run" "Description"
  printf "%-20s %-18s %-8s %-22s %s\n" "---" "----" "-------" "--------" "-----------"

  for job_file in "$JOB_DIR"/*.md; do
    [[ ! -f "$job_file" ]] && continue
    [[ "$(basename "$job_file")" == *.memory.md ]] && continue
    has_jobs=1

    parse_frontmatter "$job_file"
    local job_name
    job_name=$(basename "$job_file" .md)

    # Find last run from logs
    local last_run="—"
    local job_log_dir="${LOG_DIR}/jobs/${job_name}"
    if [[ -d "$job_log_dir" ]]; then
      local latest_log
      latest_log=$(ls -t "$job_log_dir"/*.log 2>/dev/null | head -1)
      if [[ -n "$latest_log" ]]; then
        last_run=$(basename "$latest_log" .log | tr '_' ' ')
      fi
    fi

    local enabled_mark="yes"
    [[ "$JOB_ENABLED" == "false" ]] && enabled_mark="no"

    # Check if running (lock exists)
    local lock_file="$script_install_folder/locks/${job_name}.lock"
    if [[ -f "$lock_file" ]]; then
      local lock_pid
      lock_pid=$(cat "$lock_file" 2>/dev/null)
      if kill -0 "$lock_pid" 2>/dev/null; then
        enabled_mark="RUNNING"
      fi
    fi

    local desc="$JOB_DESCRIPTION"
    [[ -n "$JOB_RUN" ]] && desc="[shell] $desc"
    [[ -n "$JOB_PRECHECK" ]] && desc="[precheck] $desc"
    printf "%-20s %-18s %-8s %-22s %s\n" "$job_name" "$JOB_CRON" "$enabled_mark" "$last_run" "$desc"
  done

  if [[ $has_jobs -eq 0 ]]; then
    IO:print "No jobs found in $JOB_DIR"
  fi
}

function do_add() {
  local source_file="$1"
  [[ -z "$source_file" ]] && IO:die "Usage: $script_basename add <file.md>"
  [[ ! -f "$source_file" ]] && IO:die "File not found: $source_file"

  # Validate frontmatter has cron field
  local cron_check
  cron_check=$(awk '/^---$/{n++; next} n==1 && /^cron:/{print "ok"; exit}' "$source_file")
  [[ -z "$cron_check" ]] && IO:die "Job file must have a 'cron:' field in YAML frontmatter"

  [[ ! -d "$JOB_DIR" ]] && mkdir -p "$JOB_DIR"

  local dest="${JOB_DIR}/$(basename "$source_file")"
  if [[ -f "$dest" ]] && ! ((FORCE)); then
    IO:confirm "Job $(basename "$source_file") already exists. Overwrite?" || return 1
  fi

  cp "$source_file" "$dest"
  IO:success "Added job: $(basename "$source_file" .md)"
}

function do_remove() {
  local job_name="$1"
  [[ -z "$job_name" ]] && IO:die "Usage: $script_basename remove <name>"

  local job_file="${JOB_DIR}/${job_name}.md"
  [[ ! -f "$job_file" ]] && IO:die "Job not found: $job_name"

  if ! ((FORCE)); then
    IO:confirm "Remove job '$job_name'?" || return 1
  fi

  rm -f "$job_file"
  # Also remove memory file if exists
  rm -f "${JOB_DIR}/${job_name}.memory.md"
  # Remove lock if exists
  release_lock "$job_name"
  IO:success "Removed job: $job_name"
}

function do_enable() {
  local job_name="$1"
  [[ -z "$job_name" ]] && IO:die "Usage: $script_basename enable <name>"

  local job_file="${JOB_DIR}/${job_name}.md"
  [[ ! -f "$job_file" ]] && IO:die "Job not found: $job_name"

  if grep -q '^enabled:' "$job_file"; then
    sed -i.bak 's/^enabled:.*/enabled: true/' "$job_file" && rm -f "${job_file}.bak"
  else
    # Add enabled field after cron line
    sed -i.bak '/^cron:/a\
enabled: true' "$job_file" && rm -f "${job_file}.bak"
  fi
  IO:success "Enabled job: $job_name"
}

function do_disable() {
  local job_name="$1"
  [[ -z "$job_name" ]] && IO:die "Usage: $script_basename disable <name>"

  local job_file="${JOB_DIR}/${job_name}.md"
  [[ ! -f "$job_file" ]] && IO:die "Job not found: $job_name"

  if grep -q '^enabled:' "$job_file"; then
    sed -i.bak 's/^enabled:.*/enabled: false/' "$job_file" && rm -f "${job_file}.bak"
  else
    sed -i.bak '/^cron:/a\
enabled: false' "$job_file" && rm -f "${job_file}.bak"
  fi
  IO:success "Disabled job: $job_name"
}

function do_history() {
  local job_name="$1"
  local log_base="${LOG_DIR}/jobs"

  if [[ -n "$job_name" ]]; then
    # Show history for specific job
    local job_log_dir="${log_base}/${job_name}"
    if [[ ! -d "$job_log_dir" ]]; then
      IO:print "No history for job: $job_name"
      return 0
    fi
    IO:print "## History: $job_name"
    IO:print ""
    printf "%-20s %-10s %s\n" "Timestamp" "Result" "Duration"
    printf "%-20s %-10s %s\n" "---------" "------" "--------"
    for log_file in $(ls -t "$job_log_dir"/*.log 2>/dev/null | head -20); do
      local timestamp result_line
      timestamp=$(basename "$log_file" .log | tr '_' ' ')
      result_line=$(tail -1 "$log_file")
      local status="unknown" duration=""
      if [[ "$result_line" == ---EXIT:* ]]; then
        if [[ "$result_line" == *"EXIT:0"* ]]; then
          status="OK"
        elif [[ "$result_line" == *"TIMEOUT"* ]]; then
          status="TIMEOUT"
        else
          status="FAIL"
        fi
        duration=$(echo "$result_line" | grep -o 'DURATION:[^ ]*' | cut -d: -f2)
      fi
      printf "%-20s %-10s %s\n" "$timestamp" "$status" "${duration:-—}"
    done
  else
    # Show history for all jobs
    if [[ ! -d "$log_base" ]]; then
      IO:print "No execution history found"
      return 0
    fi
    IO:print "## Recent executions (last 20)"
    IO:print ""
    printf "%-16s %-20s %-10s %s\n" "Job" "Timestamp" "Result" "Duration"
    printf "%-16s %-20s %-10s %s\n" "---" "---------" "------" "--------"
    # Find all log files, sort by time, show last 20
    find "$log_base" -name "*.log" -type f -print0 2>/dev/null |
      xargs -0 ls -t 2>/dev/null |
      head -20 |
      while IFS= read -r log_file; do
        local jname timestamp result_line
        jname=$(basename "$(dirname "$log_file")")
        timestamp=$(basename "$log_file" .log | tr '_' ' ')
        result_line=$(tail -1 "$log_file")
        local status="unknown" duration=""
        if [[ "$result_line" == ---EXIT:* ]]; then
          if [[ "$result_line" == *"EXIT:0"* ]]; then
            status="OK"
          elif [[ "$result_line" == *"TIMEOUT"* ]]; then
            status="TIMEOUT"
          else
            status="FAIL"
          fi
          duration=$(echo "$result_line" | grep -o 'DURATION:[^ ]*' | cut -d: -f2)
        fi
        printf "%-16s %-20s %-10s %s\n" "$jname" "$timestamp" "$status" "${duration:-—}"
      done
  fi
}

function do_test() {
  local job_name="$1"
  [[ -z "$job_name" ]] && IO:die "Usage: $script_basename test <name>"

  local job_file="${JOB_DIR}/${job_name}.md"
  [[ ! -f "$job_file" ]] && IO:die "Job not found: $job_name"

  parse_frontmatter "$job_file"

  IO:print "## Dry-run: $job_name"
  IO:print ""
  IO:print "File      : $job_file"
  IO:print "Cron      : $JOB_CRON"
  IO:print "Enabled   : $JOB_ENABLED"
  IO:print "Timeout   : ${JOB_TIMEOUT}s"
  IO:print "Singleton : $JOB_SINGLETON"
  IO:print "Continue  : $JOB_CONTINUE"
  IO:print "Memory    : $JOB_MEMORY"
  IO:print "Sandbox   : $JOB_SANDBOX"
  [[ -n "$JOB_MODEL" ]] && IO:print "Model     : $JOB_MODEL"
  [[ -n "$JOB_MAX_TURNS" ]] && IO:print "Max turns : $JOB_MAX_TURNS"
  [[ -n "$JOB_ALLOWEDTOOLS" ]] && IO:print "Tools     : $JOB_ALLOWEDTOOLS"
  [[ -n "$JOB_WORKDIR" ]] && IO:print "Workdir   : $JOB_WORKDIR"
  [[ -n "$JOB_NOTIFY_ON_FAILURE" ]] && IO:print "On fail   : $JOB_NOTIFY_ON_FAILURE"
  [[ -n "$JOB_NOTIFY_ON_SUCCESS" ]] && IO:print "On success: $JOB_NOTIFY_ON_SUCCESS"
  [[ -n "$JOB_RUN" ]] && IO:print "Run       : $JOB_RUN (no LLM)"
  [[ -n "$JOB_DESCRIPTION" ]] && IO:print "Desc      : $JOB_DESCRIPTION"

  # Check if cron matches NOW
  local match_result
  match_result=$(echo "${job_name}|${JOB_CRON}" | awk -v now_min="$(date +%-M)" \
    -v now_hour="$(date +%-H)" \
    -v now_dom="$(date +%-d)" \
    -v now_month="$(date +%-m)" \
    -v now_dow="$(date +%-u)" \
    'BEGIN { FS="|"
    split("MON,TUE,WED,THU,FRI,SAT,SUN", dn, ",")
    for (i in dn) dow_map[dn[i]] = i
  }
  function field_match(pattern, value, fmin, fmax,    parts, i, lo, hi, step, rng, v) {
    if (pattern == "*") return 1
    step = 1
    if (index(pattern, "/")) {
      split(pattern, parts, "/")
      step = parts[2] + 0
      pattern = parts[1]
    }
    if (pattern == "*") {
      return ((value - fmin) % step == 0) ? 1 : 0
    }
    split(pattern, parts, ",")
    for (i in parts) {
      gsub(/ /, "", parts[i])
      if (toupper(parts[i]) in dow_map) parts[i] = dow_map[toupper(parts[i])]
      if (index(parts[i], "-")) {
        split(parts[i], rng, "-")
        lo = (toupper(rng[1]) in dow_map) ? dow_map[toupper(rng[1])] : rng[1] + 0
        hi = (toupper(rng[2]) in dow_map) ? dow_map[toupper(rng[2])] : rng[2] + 0
        for (v = lo; v <= hi; v += step) {
          if (v == value) return 1
        }
      } else {
        if (parts[i] + 0 == value) return 1
      }
    }
    return 0
  }
  /\|/ {
    cron = $2
    split(cron, f, " ")
    if (field_match(f[1], now_min, 0, 59) &&
        field_match(f[2], now_hour, 0, 23) &&
        field_match(f[3], now_dom, 1, 31) &&
        field_match(f[4], now_month, 1, 12) &&
        field_match(f[5], now_dow, 1, 7)) {
      print "MATCH"
    } else {
      print "NO_MATCH"
    }
  }')

  IO:print ""
  if [[ "$match_result" == "MATCH" ]]; then
    IO:success "Cron MATCHES current time ($(date +%H:%M) $(date +%A))"
  else
    IO:print "Cron does NOT match current time ($(date +%H:%M) $(date +%A))"
  fi

  # Show prompt preview
  IO:print ""
  IO:print "## Prompt preview (first 10 lines):"
  extract_prompt "$job_file" | head -10

  # Check memory file
  if [[ "$JOB_MEMORY" == "true" ]]; then
    local memory_file="${JOB_DIR}/${job_name}.memory.md"
    IO:print ""
    if [[ -f "$memory_file" ]]; then
      IO:print "Memory file: $memory_file ($(wc -l <"$memory_file") lines)"
    else
      IO:print "Memory file: $memory_file (will be created on first run)"
    fi
  fi
}

function do_install() {
  Os:require "crontab"
  local script_path
  script_path="$(cd "$script_install_folder" && pwd)/$script_basename"

  local log_dir="${script_install_folder}/../logs"
  mkdir -p "$log_dir"
  local cron_entry="* * * * * $script_path run -Q >> ${log_dir}/tropicron.\$(date '+\%Y-\%m-\%d').log 2>&1"

  if crontab -l 2>/dev/null | grep -q "tropicron.*run"; then
    IO:alert "tropicron already in crontab:"
    crontab -l 2>/dev/null | grep "tropicron"
    return 0
  fi

  (crontab -l 2>/dev/null; echo "$cron_entry") | crontab -
  IO:success "Added tropicron to crontab"
  IO:print "Entry: $cron_entry"
}

function do_uninstall() {
  if ! crontab -l 2>/dev/null | grep -q "tropicron.*run"; then
    IO:print "tropicron not found in crontab"
    return 0
  fi

  if ! ((FORCE)); then
    IO:confirm "Remove tropicron from crontab?" || return 1
  fi

  crontab -l 2>/dev/null | grep -v "tropicron.*run" | crontab -
  IO:success "Removed tropicron from crontab"
}

#####################################################################
################### DO NOT MODIFY BELOW THIS LINE ###################
#####################################################################
action=""
error_prefix=""
git_repo_remote=""
git_repo_root=""
install_package=""
os_kernel=""
os_machine=""
os_name=""
os_version=""
script_basename=""
script_hash="?"
script_lines="?"
script_prefix=""
shell_brand=""
shell_version=""
temp_files=()

# set strict mode -  via http://redsymbol.net/articles/unofficial-bash-strict-mode/
# removed -e because it made basic [[ testing ]] difficult
set -uo pipefail
IFS=$'\n\t'
FORCE=0
help=0

#to enable VERBOSE even before option parsing
VERBOSE=0
[[ $# -gt 0 ]] && [[ $1 == "-v" ]] && VERBOSE=1

#to enable QUIET even before option parsing
QUIET=0
[[ $# -gt 0 ]] && [[ $1 == "-q" ]] && QUIET=1

txtReset=""
txtError=""
txtInfo=""
txtInfo=""
txtWarn=""
txtBold=""
txtItalic=""
txtUnderline=""

char_succes="OK "
char_fail="!! "
char_alert="?? "
char_wait="..."
info_icon="(i)"
config_icon="[c]"
clean_icon="[c]"
require_icon="[r]"

### stdIO:print/stderr output
function IO:initialize() {
  script_started_at="$(Tool:time)"
  IO:debug "script $script_basename started at $script_started_at"

  [[ "${BASH_SOURCE[0]:-}" != "${0}" ]] && sourced=1 || sourced=0
  [[ -t 1 ]] && piped=0 || piped=1 # detect if output is piped
  if [[ $piped -eq 0 && -n "$TERM" ]]; then
    txtReset=$(tput sgr0)
    txtError=$(tput setaf 160)
    txtInfo=$(tput setaf 2)
    txtWarn=$(tput setaf 214)
    txtBold=$(tput bold)
    txtItalic=$(tput sitm)
    txtUnderline=$(tput smul)
  fi

  [[ $(echo -e '\xe2\x82\xac') == '€' ]] && unicode=1 || unicode=0 # detect if unicode is supported
  if [[ $unicode -gt 0 ]]; then
    char_succes="✅"
    char_fail="⛔"
    char_alert="✴️"
    char_wait="⏳"
    info_icon="🌼"
    config_icon="🌱"
    clean_icon="🧽"
    require_icon="🔌"
  fi
  error_prefix="${txtError}>${txtReset}"
}

function IO:print() {
  ((QUIET)) && true || printf '%b\n' "$*"
}

function IO:debug() {
  ((VERBOSE)) && IO:print "${txtInfo}# $* ${txtReset}" >&2
  true
}

function IO:die() {
  IO:print "${txtError}${char_fail} $script_basename${txtReset}: $*" >&2
  Os:beep
  Script:exit
}

function IO:alert() {
  IO:print "${txtWarn}${char_alert}${txtReset}: ${txtUnderline}$*${txtReset}" >&2
}

function IO:success() {
  IO:print "${txtInfo}${char_succes}${txtReset}  ${txtBold}$*${txtReset}"
}

function IO:announce() {
  IO:print "${txtInfo}${char_wait}${txtReset}  ${txtItalic}$*${txtReset}"
  sleep 1
}

function IO:progress() {
  ((QUIET)) || (
    local screen_width
    screen_width=$(tput cols 2>/dev/null || echo 80)
    local rest_of_line
    rest_of_line=$((screen_width - 5))

    if ((piped)); then
      IO:print "... $*" >&2
    else
      printf "... %-${rest_of_line}b\r" "$*                                             " >&2
    fi
  )
}

function IO:countdown() {
  local seconds=${1:-5}
  local message=${2:-Countdown :}
  local i

  if ((piped)); then
    IO:print "$message $seconds seconds"
  else
    for ((i = 0; i < "$seconds"; i++)); do
      IO:progress "${txtInfo}$message $((seconds - i)) seconds${txtReset}"
      sleep 1
    done
    IO:print "                         "
  fi
}

### interactive
function IO:confirm() {
  ((FORCE)) && return 0
  read -r -p "$1 [y/N] " -n 1
  echo " "
  [[ $REPLY =~ ^[Yy]$ ]]
}

function IO:question() {
  local ANSWER
  local DEFAULT=${2:-}
  read -r -p "$1 ($DEFAULT) > " ANSWER
  [[ -z "$ANSWER" ]] && echo "$DEFAULT" || echo "$ANSWER"
}

function IO:log() {
  [[ -n "${log_file:-}" ]] && echo "$(date '+%H:%M:%S') | $*" >>"$log_file"
}

function Tool:calc() {
  awk "BEGIN {print $*} ; "
}

function Tool:round() {
  local number="${1}"
  local decimals="${2:-0}"

  awk "BEGIN {print sprintf( \"%.${decimals}f\" , $number )};"
}

function Tool:time() {
  if [[ $(command -v perl) ]]; then
    perl -MTime::HiRes=time -e 'printf "%f\n", time'
  elif [[ $(command -v php) ]]; then
    php -r 'printf("%f\n",microtime(true));'
  elif [[ $(command -v python) ]]; then
    python -c 'import time; print(time.time()) '
  elif [[ $(command -v python3) ]]; then
    python3 -c 'import time; print(time.time()) '
  elif [[ $(command -v node) ]]; then
    node -e 'console.log(+new Date() / 1000)'
  elif [[ $(command -v ruby) ]]; then
    ruby -e 'STDOUT.puts(Time.now.to_f)'
  else
    date '+%s.000'
  fi
}

function Tool:throughput() {
  local time_started="$1"
  [[ -z "$time_started" ]] && time_started="$script_started_at"
  local operations="${2:-1}"
  local name="${3:-operation}"

  local time_finished
  local duration
  local seconds
  time_finished="$(Tool:time)"
  duration="$(Tool:calc "$time_finished - $time_started")"
  seconds="$(Tool:round "$duration")"
  local ops
  if [[ "$operations" -gt 1 ]]; then
    if [[ $operations -gt $seconds ]]; then
      ops=$(Tool:calc "$operations / $duration")
      ops=$(Tool:round "$ops" 3)
      duration=$(Tool:round "$duration" 2)
      IO:print "$operations $name finished in $duration secs: $ops $name/sec"
    else
      ops=$(Tool:calc "$duration / $operations")
      ops=$(Tool:round "$ops" 3)
      duration=$(Tool:round "$duration" 2)
      IO:print "$operations $name finished in $duration secs: $ops sec/$name"
    fi
  else
    duration=$(Tool:round "$duration" 2)
    IO:print "$name finished in $duration secs"
  fi
}

### string processing

function Str:trim() {
  local var="$*"
  # remove leading whitespace characters
  var="${var#"${var%%[![:space:]]*}"}"
  # remove trailing whitespace characters
  var="${var%"${var##*[![:space:]]}"}"
  printf '%s' "$var"
}

function Str:lower() {
  if [[ -n "$1" ]]; then
    local input="$*"
    echo "${input,,}"
  else
    awk '{print tolower($0)}'
  fi
}

function Str:upper() {
  if [[ -n "$1" ]]; then
    local input="$*"
    echo "${input^^}"
  else
    awk '{print toupper($0)}'
  fi
}

function Str:ascii() {
  # remove all characters with accents/diacritics to latin alphabet
  # shellcheck disable=SC2020
  sed 'y/àáâäæãåāǎçćčèéêëēėęěîïííīįìǐłñńôöòóœøōǒõßśšûüǔùǖǘǚǜúūÿžźżÀÁÂÄÆÃÅĀǍÇĆČÈÉÊËĒĖĘĚÎÏÍÍĪĮÌǏŁÑŃÔÖÒÓŒØŌǑÕẞŚŠÛÜǓÙǕǗǙǛÚŪŸŽŹŻ/aaaaaaaaaccceeeeeeeeiiiiiiiilnnooooooooosssuuuuuuuuuuyzzzAAAAAAAAACCCEEEEEEEEIIIIIIIILNNOOOOOOOOOSSSUUUUUUUUUUYZZZ/'
}

function Str:slugify() {
  # Str:slugify <input> <separator>
  # Str:slugify "Jack, Jill & Clémence LTD"      => jack-jill-clemence-ltd
  # Str:slugify "Jack, Jill & Clémence LTD" "_"  => jack_jill_clemence_ltd
  separator="${2:-}"
  [[ -z "$separator" ]] && separator="-"
  Str:lower "$1" |
    Str:ascii |
    awk '{
          gsub(/[\[\]@#$%^&*;,.:()<>!?\/+=_]/," ",$0);
          gsub(/^  */,"",$0);
          gsub(/  *$/,"",$0);
          gsub(/  */,"-",$0);
          gsub(/[^a-z0-9\-]/,"");
          print;
          }' |
    sed "s/-/$separator/g"
}

function Str:title() {
  # Str:title <input> <separator>
  # Str:title "Jack, Jill & Clémence LTD"     => JackJillClemenceLtd
  # Str:title "Jack, Jill & Clémence LTD" "_" => Jack_Jill_Clemence_Ltd
  separator="${2:-}"
  # shellcheck disable=SC2020
  Str:lower "$1" |
    tr 'àáâäæãåāçćčèéêëēėęîïííīįìłñńôöòóœøōõßśšûüùúūÿžźż' 'aaaaaaaaccceeeeeeeiiiiiiilnnoooooooosssuuuuuyzzz' |
    awk '{ gsub(/[\[\]@#$%^&*;,.:()<>!?\/+=_-]/," ",$0); print $0; }' |
    awk '{
          for (i=1; i<=NF; ++i) {
              $i = toupper(substr($i,1,1)) tolower(substr($i,2))
          };
          print $0;
          }' |
    sed "s/ /$separator/g" |
    cut -c1-50
}

function Str:digest() {
  local length=${1:-6}
  if [[ -n $(command -v md5sum) ]]; then
    # regular linux
    md5sum | cut -c1-"$length"
  else
    # macos
    md5 | cut -c1-"$length"
  fi
}

# Gha: function should only be run inside of a Github Action

function Gha:finish() {
  [[ -z "${RUNNER_OS:-}" ]] && IO:die "This should only run inside a Github Action, don't run it on your machine"
  local timestamp message
  git config user.name "Bashew Runner"
  git config user.email "actions@users.noreply.github.com"
  git add -A
  timestamp="$(date -u)"
  message="$timestamp < $script_basename $script_version"
  IO:print "Commit Message: $message"
  git commit -m "${message}" || exit 0
  git pull --rebase
  git push
  IO:success "Commit OK!"
}

trap "IO:die \"ERROR \$? after \$SECONDS seconds \n\
\${error_prefix} last command : '\$BASH_COMMAND' \" \
\$(< \$script_install_path awk -v lineno=\$LINENO \
'NR == lineno {print \"\${error_prefix} from line \" lineno \" : \" \$0}')" INT TERM EXIT
# cf https://askubuntu.com/questions/513932/what-is-the-bash-command-variable-good-for

Script:exit() {
  local temp_file
  for temp_file in "${temp_files[@]-}"; do
    [[ -f "$temp_file" ]] && (
      IO:debug "Delete temp file [$temp_file]"
      rm -f "$temp_file"
    )
  done
  trap - INT TERM EXIT
  IO:debug "$script_basename finished after $SECONDS seconds"
  exit 0
}

Script:check_version() {
  (
    # shellcheck disable=SC2164
    pushd "$script_install_folder" &>/dev/null
    if [[ -d .git ]]; then
      local remote
      remote="$(git remote -v | grep fetch | awk 'NR == 1 {print $2}')"
      IO:progress "Check for updates - $remote"
      git remote update &>/dev/null
      if [[ $(git rev-list --count "HEAD...HEAD@{upstream}" 2>/dev/null) -gt 0 ]]; then
        IO:print "There is a more recent update of this script - run <<$script_prefix update>> to update"
      else
        IO:progress "                                         "
      fi
    fi
    # shellcheck disable=SC2164
    popd &>/dev/null
  )
}

Script:git_pull() {
  # run in background to avoid problems with modifying a running interpreted script
  (
    sleep 1
    cd "$script_install_folder" && git pull
  ) &
}

Script:show_tips() {
  ((sourced)) && return 0
  # shellcheck disable=SC2016
  grep <"${BASH_SOURCE[0]}" -v '$0' |
    awk \
      -v green="$txtInfo" \
      -v yellow="$txtWarn" \
      -v reset="$txtReset" \
      '
      /TIP: /  {$1=""; gsub(/«/,green); gsub(/»/,reset); print "*" $0}
      /TIP:> / {$1=""; print " " yellow $0 reset}
      ' |
    awk \
      -v script_basename="$script_basename" \
      -v script_prefix="$script_prefix" \
      '{
      gsub(/\$script_basename/,script_basename);
      gsub(/\$script_prefix/,script_prefix);
      print ;
      }'
}

Script:check() {
  local name
  if [[ -n $(Option:filter flag) ]]; then
    IO:print "## ${txtInfo}boolean flags${txtReset}:"
    Option:filter flag |
      grep -v help |
      while read -r name; do
        declare -p "$name" | cut -d' ' -f3-
      done
  fi

  if [[ -n $(Option:filter option) ]]; then
    IO:print "## ${txtInfo}option defaults${txtReset}:"
    Option:filter option |
      while read -r name; do
        declare -p "$name" | cut -d' ' -f3-
      done
  fi

  if [[ -n $(Option:filter list) ]]; then
    IO:print "## ${txtInfo}list options${txtReset}:"
    Option:filter list |
      while read -r name; do
        declare -p "$name" | cut -d' ' -f3-
      done
  fi

  if [[ -n $(Option:filter param) ]]; then
    if ((piped)); then
      IO:debug "Skip parameters for .env files"
    else
      IO:print "## ${txtInfo}parameters${txtReset}:"
      Option:filter param |
        while read -r name; do
          declare -p "$name" | cut -d' ' -f3-
        done
    fi
  fi

  if [[ -n $(Option:filter choice) ]]; then
    if ((piped)); then
      IO:debug "Skip choices for .env files"
    else
      IO:print "## ${txtInfo}choice${txtReset}:"
      Option:filter choice |
        while read -r name; do
          declare -p "$name" | cut -d' ' -f3-
        done
    fi
  fi

  IO:print "## ${txtInfo}required commands${txtReset}:"
  Script:show_required
}

Option:usage() {
  IO:print "Program : ${txtInfo}$script_basename${txtReset}  by ${txtWarn}$script_author${txtReset}"
  IO:print "Version : ${txtInfo}v$script_version${txtReset} (${txtWarn}$script_modified${txtReset})"
  IO:print "Purpose : ${txtInfo}$script_description${txtReset}"
  echo -n "Usage   : $script_basename"
  Option:config |
    awk '
  BEGIN { FS="|"; OFS=" "; oneline="" ; fulltext="Flags, options and parameters:"}
  $1 ~ /flag/  {
    fulltext = fulltext sprintf("\n    -%1s|--%-12s: [flag] %s [default: off]",$2,$3,$4) ;
    oneline  = oneline " [-" $2 "]"
    }
  $1 ~ /option/  {
    fulltext = fulltext sprintf("\n    -%1s|--%-12s: [option] %s",$2,$3 " <?>",$4) ;
    if($5!=""){fulltext = fulltext "  [default: " $5 "]"; }
    oneline  = oneline " [-" $2 " <" $3 ">]"
    }
  $1 ~ /list/  {
    fulltext = fulltext sprintf("\n    -%1s|--%-12s: [list] %s (array)",$2,$3 " <?>",$4) ;
    fulltext = fulltext "  [default empty]";
    oneline  = oneline " [-" $2 " <" $3 ">]"
    }
  $1 ~ /secret/  {
    fulltext = fulltext sprintf("\n    -%1s|--%s <%s>: [secret] %s",$2,$3,"?",$4) ;
      oneline  = oneline " [-" $2 " <" $3 ">]"
    }
  $1 ~ /param/ {
    if($2 == "1"){
          fulltext = fulltext sprintf("\n    %-17s: [parameter] %s","<"$3">",$4);
          oneline  = oneline " <" $3 ">"
     }
     if($2 == "?"){
          fulltext = fulltext sprintf("\n    %-17s: [parameter] %s (optional)","<"$3">",$4);
          oneline  = oneline " <" $3 "?>"
     }
     if($2 == "n"){
          fulltext = fulltext sprintf("\n    %-17s: [parameters] %s (1 or more)","<"$3">",$4);
          oneline  = oneline " <" $3 " …>"
     }
    }
  $1 ~ /choice/ {
        fulltext = fulltext sprintf("\n    %-17s: [choice] %s","<"$3">",$4);
        if($5!=""){fulltext = fulltext "  [options: " $5 "]"; }
        oneline  = oneline " <" $3 ">"
    }
    END {print oneline; print fulltext}
  '
}

function Option:filter() {
  Option:config | grep "$1|" | cut -d'|' -f3 | sort | grep -v '^\s*$'
}

function Script:show_required() {
  grep 'Os:require' "$script_install_path" |
    grep -v -E '\(\)|grep|# Os:require' |
    awk -v install="# $install_package " '
    function ltrim(s) { sub(/^[ "\t\r\n]+/, "", s); return s }
    function rtrim(s) { sub(/[ "\t\r\n]+$/, "", s); return s }
    function trim(s) { return rtrim(ltrim(s)); }
    NF == 2 {print install trim($2); }
    NF == 3 {print install trim($3); }
    NF > 3  {$1=""; $2=""; $0=trim($0); print "# " trim($0);}
  ' |
    sort -u
}

function Option:initialize() {
  local init_command
  init_command=$(Option:config |
    grep -v "VERBOSE|" |
    awk '
    BEGIN { FS="|"; OFS=" ";}
    $1 ~ /flag/   && $5 == "" {print $3 "=0; "}
    $1 ~ /flag/   && $5 != "" {print $3 "=\"" $5 "\"; "}
    $1 ~ /option/ && $5 == "" {print $3 "=\"\"; "}
    $1 ~ /option/ && $5 != "" {print $3 "=\"" $5 "\"; "}
    $1 ~ /choice/   {print $3 "=\"\"; "}
    $1 ~ /list/     {print $3 "=(); "}
    $1 ~ /secret/   {print $3 "=\"\"; "}
    ')
  if [[ -n "$init_command" ]]; then
    eval "$init_command"
  fi
}

function Option:has_single() { Option:config | grep 'param|1|' >/dev/null; }
function Option:has_choice() { Option:config | grep 'choice|1' >/dev/null; }
function Option:has_optional() { Option:config | grep 'param|?|' >/dev/null; }
function Option:has_multi() { Option:config | grep 'param|n|' >/dev/null; }

function Option:parse() {
  if [[ $# -eq 0 ]]; then
    Option:usage >&2
    Script:exit
  fi

  ## first process all the -x --xxxx flags and options
  while true; do
    # flag <flag> is saved as $flag = 0/1
    # option <option> is saved as $option
    if [[ $# -eq 0 ]]; then
      ## all parameters processed
      break
    fi
    if [[ ! $1 == -?* ]]; then
      ## all flags/options processed
      break
    fi
    local save_option
    save_option=$(Option:config |
      awk -v opt="$1" '
        BEGIN { FS="|"; OFS=" ";}
        $1 ~ /flag/   &&  "-"$2 == opt {print $3"=1"}
        $1 ~ /flag/   && "--"$3 == opt {print $3"=1"}
        $1 ~ /option/ &&  "-"$2 == opt {print $3"=${2:-}; shift"}
        $1 ~ /option/ && "--"$3 == opt {print $3"=${2:-}; shift"}
        $1 ~ /list/ &&  "-"$2 == opt {print $3"+=(${2:-}); shift"}
        $1 ~ /list/ && "--"$3 == opt {print $3"=(${2:-}); shift"}
        $1 ~ /secret/ &&  "-"$2 == opt {print $3"=${2:-}; shift #noshow"}
        $1 ~ /secret/ && "--"$3 == opt {print $3"=${2:-}; shift #noshow"}
        ')
    if [[ -n "$save_option" ]]; then
      if echo "$save_option" | grep shift >>/dev/null; then
        local save_var
        save_var=$(echo "$save_option" | cut -d= -f1)
        IO:debug "$config_icon parameter: ${save_var}=$2"
      else
        IO:debug "$config_icon flag: $save_option"
      fi
      eval "$save_option"
    else
      IO:die "cannot interpret option [$1]"
    fi
    shift
  done

  ((help)) && (
    Option:usage
    Script:check_version
    IO:print "                                  "
    echo "### TIPS & EXAMPLES"
    Script:show_tips

  ) && Script:exit

  local option_list
  local option_count
  local choices
  local single_params
  ## then run through the given parameters
  if Option:has_choice; then
    choices=$(Option:config | awk -F"|" '
      $1 == "choice" && $2 == 1 {print $3}
      ')
    option_list=$(xargs <<<"$choices")
    option_count=$(wc <<<"$choices" -w | xargs)
    IO:debug "$config_icon Expect : $option_count choice(s): $option_list"
    [[ $# -eq 0 ]] && IO:die "need the choice(s) [$option_list]"

    local choices_list
    local valid_choice
    local param
    for param in $choices; do
      [[ $# -eq 0 ]] && IO:die "need choice [$param]"
      [[ -z "$1" ]] && IO:die "need choice [$param]"
      IO:debug "$config_icon Assign : $param=$1"
      # check if choice is in list
      choices_list=$(Option:config | awk -F"|" -v choice="$param" '$1 == "choice" && $3 = choice {print $5}')
      valid_choice=$(tr <<<"$choices_list" "," "\n" | grep "$1")
      [[ -z "$valid_choice" ]] && IO:die "choice [$1] is not valid, should be in list [$choices_list]"

      eval "$param=\"$1\""
      shift
    done
  else
    IO:debug "$config_icon No choices to process"
    choices=""
    option_count=0
  fi

  if Option:has_single; then
    single_params=$(Option:config | awk -F"|" '
      $1 == "param" && $2 == 1 {print $3}
      ')
    option_list=$(xargs <<<"$single_params")
    option_count=$(wc <<<"$single_params" -w | xargs)
    IO:debug "$config_icon Expect : $option_count single parameter(s): $option_list"
    [[ $# -eq 0 ]] && IO:die "need the parameter(s) [$option_list]"

    for param in $single_params; do
      [[ $# -eq 0 ]] && IO:die "need parameter [$param]"
      [[ -z "$1" ]] && IO:die "need parameter [$param]"
      IO:debug "$config_icon Assign : $param=$1"
      eval "$param=\"$1\""
      shift
    done
  else
    IO:debug "$config_icon No single params to process"
    single_params=""
    option_count=0
  fi

  if Option:has_optional; then
    local optional_params
    local optional_count
    optional_params=$(Option:config | grep 'param|?|' | cut -d'|' -f3)
    optional_count=$(wc <<<"$optional_params" -w | xargs)
    IO:debug "$config_icon Expect : $optional_count optional parameter(s): $(echo "$optional_params" | xargs)"

    for param in $optional_params; do
      IO:debug "$config_icon Assign : $param=${1:-}"
      eval "$param=\"${1:-}\""
      shift
    done
  else
    IO:debug "$config_icon No optional params to process"
    optional_params=""
    optional_count=0
  fi

  if Option:has_multi; then
    #IO:debug "Process: multi param"
    local multi_count
    local multi_param
    multi_count=$(Option:config | grep -c 'param|n|')
    multi_param=$(Option:config | grep 'param|n|' | cut -d'|' -f3)
    IO:debug "$config_icon Expect : $multi_count multi parameter: $multi_param"
    ((multi_count > 1)) && IO:die "cannot have >1 'multi' parameter: [$multi_param]"
    ((multi_count > 0)) && [[ $# -eq 0 ]] && IO:die "need the (multi) parameter [$multi_param]"
    # save the rest of the params in the multi param
    if [[ -n "$*" ]]; then
      IO:debug "$config_icon Assign : $multi_param=$*"
      eval "$multi_param=( $* )"
    fi
  else
    multi_count=0
    multi_param=""
    [[ $# -gt 0 ]] && IO:die "cannot interpret extra parameters"
  fi
}

function Os:require() {
  local install_instructions
  local binary
  local words
  local path_binary
  # $1 = binary that is required
  binary="$1"
  path_binary=$(command -v "$binary" 2>/dev/null)
  [[ -n "$path_binary" ]] && IO:debug "️$require_icon required [$binary] -> $path_binary" && return 0
  # $2 = how to install it
  IO:alert "$script_basename needs [$binary] but it cannot be found"
  words=$(echo "${2:-}" | wc -w)
  install_instructions="$install_package $1"
  [[ $words -eq 1 ]] && install_instructions="$install_package $2"
  [[ $words -gt 1 ]] && install_instructions="${2:-}"
  if ((FORCE)); then
    IO:announce "Installing [$1] ..."
    eval "$install_instructions"
  else
    IO:alert "1) install package  : $install_instructions"
    IO:alert "2) check path       : export PATH=\"[path of your binary]:\$PATH\""
    IO:die "Missing program/script [$binary]"
  fi
}

function Os:folder() {
  if [[ -n "$1" ]]; then
    local folder="$1"
    local max_days=${2:-365}
    if [[ ! -d "$folder" ]]; then
      IO:debug "$clean_icon Create folder : [$folder]"
      mkdir -p "$folder"
    else
      IO:debug "$clean_icon Cleanup folder: [$folder] - delete files older than $max_days day(s)"
      find "$folder" -mtime "+$max_days" -type f -exec rm {} \;
    fi
  fi
}

function Os:follow_link() {
  [[ ! -L "$1" ]] && echo "$1" && return 0 ## if it's not a symbolic link, return immediately
  local file_folder link_folder link_name symlink
  file_folder="$(dirname "$1")"                                                                                   ## check if file has absolute/relative/no path
  [[ "$file_folder" != /* ]] && file_folder="$(cd -P "$file_folder" &>/dev/null && pwd)"                          ## a relative path was given, resolve it
  symlink=$(readlink "$1")                                                                                        ## follow the link
  link_folder=$(dirname "$symlink")                                                                               ## check if link has absolute/relative/no path
  [[ -z "$link_folder" ]] && link_folder="$file_folder"                                                           ## if no link path, stay in same folder
  [[ "$link_folder" == \.* ]] && link_folder="$(cd -P "$file_folder" && cd -P "$link_folder" &>/dev/null && pwd)" ## a relative link path was given, resolve it
  link_name=$(basename "$symlink")
  IO:debug "$info_icon Symbolic ln: $1 -> [$link_folder/$link_name]"
  Os:follow_link "$link_folder/$link_name" ## recurse
}

function Os:notify() {
  # cf https://levelup.gitconnected.com/5-modern-bash-scripting-techniques-that-only-a-few-programmers-know-4abb58ddadad
  local message="$1"
  local source="${2:-$script_basename}"

  [[ -n $(command -v notify-send) ]] && notify-send "$source" "$message"                                      # for Linux
  [[ -n $(command -v osascript) ]] && osascript -e "display notification \"$message\" with title \"$source\"" # for MacOS
}

function Os:busy() {
  # show spinner as long as process $pid is running
  local pid="$1"
  local message="${2:-}"
  local frames=("|" "/" "-" "\\")
  (
    while kill -0 "$pid" &>/dev/null; do
      for frame in "${frames[@]}"; do
        printf "\r[ $frame ] %s..." "$message"
        sleep 0.5
      done
    done
    printf "\n"
  )
}

function Os:beep() {
  if [[ -n "$TERM" ]]; then
    tput bel
  fi
}

function Script:meta() {

  script_prefix=$(basename "${BASH_SOURCE[0]}" .sh)
  script_basename=$(basename "${BASH_SOURCE[0]}")
  execution_day=$(date "+%Y-%m-%d")

  script_install_path="${BASH_SOURCE[0]}"
  IO:debug "$info_icon Script path: $script_install_path"
  script_install_path=$(Os:follow_link "$script_install_path")
  IO:debug "$info_icon Linked path: $script_install_path"
  script_install_folder="$(cd -P "$(dirname "$script_install_path")" && pwd)"
  IO:debug "$info_icon In folder  : $script_install_folder"
  if [[ -f "$script_install_path" ]]; then
    script_hash=$(Str:digest <"$script_install_path" 8)
    script_lines=$(awk <"$script_install_path" 'END {print NR}')
  fi

  # get shell/operating system/versions
  shell_brand="sh"
  shell_version="?"
  [[ -n "${ZSH_VERSION:-}" ]] && shell_brand="zsh" && shell_version="$ZSH_VERSION"
  [[ -n "${BASH_VERSION:-}" ]] && shell_brand="bash" && shell_version="$BASH_VERSION"
  [[ -n "${FISH_VERSION:-}" ]] && shell_brand="fish" && shell_version="$FISH_VERSION"
  [[ -n "${KSH_VERSION:-}" ]] && shell_brand="ksh" && shell_version="$KSH_VERSION"
  IO:debug "$info_icon Shell type : $shell_brand - version $shell_version"
  if [[ "$shell_brand" == "bash" && "${BASH_VERSINFO:-0}" -lt 4 ]]; then
    IO:die "Bash version 4 or higher is required - current version = ${BASH_VERSINFO:-0}"
  fi

  os_kernel=$(uname -s)
  os_version=$(uname -r)
  os_machine=$(uname -m)
  install_package=""
  case "$os_kernel" in
  CYGWIN* | MSYS* | MINGW*)
    os_name="Windows"
    ;;
  Darwin)
    os_name=$(sw_vers -productName)       # macOS
    os_version=$(sw_vers -productVersion) # 11.1
    install_package="brew install"
    ;;
  Linux | GNU*)
    if [[ $(command -v lsb_release) ]]; then
      # 'normal' Linux distributions
      os_name=$(lsb_release -i | awk -F: '{$1=""; gsub(/^[\s\t]+/,"",$2); gsub(/[\s\t]+$/,"",$2); print $2}')    # Ubuntu/Raspbian
      os_version=$(lsb_release -r | awk -F: '{$1=""; gsub(/^[\s\t]+/,"",$2); gsub(/[\s\t]+$/,"",$2); print $2}') # 20.04
    else
      # Synology, QNAP,
      os_name="Linux"
    fi
    [[ -x /bin/apt-cyg ]] && install_package="apt-cyg install"     # Cygwin
    [[ -x /bin/dpkg ]] && install_package="dpkg -i"                # Synology
    [[ -x /opt/bin/ipkg ]] && install_package="ipkg install"       # Synology
    [[ -x /usr/sbin/pkg ]] && install_package="pkg install"        # BSD
    [[ -x /usr/bin/pacman ]] && install_package="pacman -S"        # Arch Linux
    [[ -x /usr/bin/zypper ]] && install_package="zypper install"   # Suse Linux
    [[ -x /usr/bin/emerge ]] && install_package="emerge"           # Gentoo
    [[ -x /usr/bin/yum ]] && install_package="yum install"         # RedHat RHEL/CentOS/Fedora
    [[ -x /usr/bin/apk ]] && install_package="apk add"             # Alpine
    [[ -x /usr/bin/apt-get ]] && install_package="apt-get install" # Debian
    [[ -x /usr/bin/apt ]] && install_package="apt install"         # Ubuntu
    ;;

  esac
  IO:debug "$info_icon System OS  : $os_name ($os_kernel) $os_version on $os_machine"
  IO:debug "$info_icon Package mgt: $install_package"

  # get last modified date of this script
  script_modified="??"
  [[ "$os_kernel" == "Linux" ]] && script_modified=$(stat -c %y "$script_install_path" 2>/dev/null | cut -c1-16) # generic linux
  [[ "$os_kernel" == "Darwin" ]] && script_modified=$(stat -f "%Sm" "$script_install_path" 2>/dev/null)          # for MacOS

  IO:debug "$info_icon Version  : $script_version"
  IO:debug "$info_icon Created  : $script_created"
  IO:debug "$info_icon Modified : $script_modified"

  IO:debug "$info_icon Lines    : $script_lines lines / md5: $script_hash"
  IO:debug "$info_icon User     : $USER@$HOSTNAME"

  # if run inside a git repo, detect for which remote repo it is
  if git status &>/dev/null; then
    git_repo_remote=$(git remote -v | awk '/(fetch)/ {print $2}')
    IO:debug "$info_icon git remote : $git_repo_remote"
    git_repo_root=$(git rev-parse --show-toplevel)
    IO:debug "$info_icon git folder : $git_repo_root"
  fi

  # get script version from VERSION.md file - which is automatically updated by pforret/setver
  [[ -f "$script_install_folder/VERSION.md" ]] && script_version=$(cat "$script_install_folder/VERSION.md")
  # get script version from git tag file - which is automatically updated by pforret/setver
  [[ -n "$git_repo_root" ]] && [[ -n "$(git tag &>/dev/null)" ]] && script_version=$(git tag --sort=version:refname | tail -1)
}

function Script:initialize() {
  log_file=""
  if [[ -n "${TMP_DIR:-}" ]]; then
    # clean up TMP folder after 1 day
    Os:folder "$TMP_DIR" 1
  fi
  if [[ -n "${LOG_DIR:-}" ]]; then
    # clean up LOG folder after 1 month
    Os:folder "$LOG_DIR" 30
    log_file="$LOG_DIR/$script_prefix.$execution_day.log"
    IO:debug "$config_icon log_file: $log_file"
  fi
}

function Os:tempfile() {
  local extension=${1:-txt}
  local file="${TMP_DIR:-/tmp}/$execution_day.$RANDOM.$extension"
  IO:debug "$config_icon tmp_file: $file"
  temp_files+=("$file")
  echo "$file"
}

function Os:import_env() {
  local env_files
  if [[ $(pwd) == "$script_install_folder" ]]; then
    env_files=(
      "$script_install_folder/.env"
      "$script_install_folder/.$script_prefix.env"
      "$script_install_folder/$script_prefix.env"
    )
  else
    env_files=(
      "$script_install_folder/.env"
      "$script_install_folder/.$script_prefix.env"
      "$script_install_folder/$script_prefix.env"
      "./.env"
      "./.$script_prefix.env"
      "./$script_prefix.env"
    )
  fi

  local env_file
  for env_file in "${env_files[@]}"; do
    if [[ -f "$env_file" ]]; then
      IO:debug "$config_icon Read  dotenv: [$env_file]"
      local clean_file
      clean_file=$(Os:clean_env "$env_file")
      # shellcheck disable=SC1090
      source "$clean_file" && rm "$clean_file"
    fi
  done
}

function Os:clean_env() {
  local input="$1"
  local output="$1.__.sh"
  [[ ! -f "$input" ]] && IO:die "Input file [$input] does not exist"
  IO:debug "$clean_icon Clean dotenv: [$output]"
  awk <"$input" '
      function ltrim(s) { sub(/^[ \t\r\n]+/, "", s); return s }
      function rtrim(s) { sub(/[ \t\r\n]+$/, "", s); return s }
      function trim(s) { return rtrim(ltrim(s)); }
      /=/ { # skip lines with no equation
        $0=trim($0);
        if(substr($0,1,1) != "#"){ # skip comments
          equal=index($0, "=");
          key=trim(substr($0,1,equal-1));
          val=trim(substr($0,equal+1));
          if(match(val,/^".*"$/) || match(val,/^\047.*\047$/)){
            print key "=" val
          } else {
            print key "=\"" val "\""
          }
        }
      }
  ' >"$output"
  echo "$output"
}

IO:initialize # output settings
Script:meta   # find installation folder

[[ $run_as_root == 1 ]] && [[ $UID -ne 0 ]] && IO:die "user is $USER, MUST be root to run [$script_basename]"
[[ $run_as_root == -1 ]] && [[ $UID -eq 0 ]] && IO:die "user is $USER, CANNOT be root to run [$script_basename]"

Option:initialize # set default values for flags & options
Os:import_env     # load .env, .<prefix>.env, <prefix>.env (script folder + cwd)

if [[ $sourced -eq 0 ]]; then
  Option:parse "$@" # overwrite with specified options if any
  Script:initialize # clean up folders
  Script:main       # run Script:main program
  Script:exit       # exit and clean up
else
  # just disable the trap, don't execute Script:main
  trap - INT TERM EXIT
fi
