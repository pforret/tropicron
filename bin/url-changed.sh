#!/usr/bin/env bash
### url-changed.sh — Fetch a URL, convert to text/markdown, detect changes
###
### Usage: url-changed.sh <url> [cache_dir]
###
### Exit 0 + empty stdout → content unchanged (precheck: skip LLM)
### Exit 0 + stdout        → content changed (precheck: trigger LLM)
###
### Stdout format when changed:
###   ## URL changed: <url>
###   ### Diff
###   <unified diff>
###   ### Previous content
###   <old content, truncated>
###   ### Current content
###   <new content>
###
### Supports: HTML (converted to markdown via lynx/pandoc/sed fallback), JSON, plain text, XML
### Requires: curl; optional: lynx or pandoc (for HTML→markdown)

set -euo pipefail

URL="${1:?Usage: url-changed.sh <url> [cache_dir]}"
CACHE_DIR="${2:-${HOME}/.cache/tropicron/url-changed}"

# Deterministic cache key from URL
url_hash=$(echo -n "$URL" | md5sum | cut -d' ' -f1)
cache_file="${CACHE_DIR}/${url_hash}.txt"
cache_meta="${CACHE_DIR}/${url_hash}.meta"

mkdir -p "$CACHE_DIR"

# --- Fetch ---------------------------------------------------------------
tmp_raw=$(mktemp)
tmp_text=$(mktemp)
trap 'rm -f "$tmp_raw" "$tmp_text"' EXIT

http_code=$(curl -sL -o "$tmp_raw" -w '%{http_code}' \
  -H "Accept: text/html,application/json,text/plain,text/markdown" \
  --max-time 30 "$URL" 2>/dev/null) || {
  echo "FETCH_ERROR: curl failed for $URL"
  exit 1
}

if [[ "$http_code" -ge 400 ]]; then
  echo "FETCH_ERROR: HTTP $http_code for $URL"
  exit 1
fi

# --- Detect content type and convert to text/markdown --------------------
content_type=$(file -b --mime-type "$tmp_raw" 2>/dev/null || echo "text/plain")

html_to_text() {
  if command -v lynx &>/dev/null; then
    lynx -dump -nolist -stdin <"$1"
  elif command -v pandoc &>/dev/null; then
    pandoc -f html -t markdown --wrap=none "$1"
  else
    # Minimal fallback: strip tags, decode common entities
    sed -e 's/<[^>]*>//g' \
        -e 's/&amp;/\&/g' -e 's/&lt;/</g' -e 's/&gt;/>/g' \
        -e 's/&quot;/"/g' -e "s/&#39;/'/g" -e 's/&nbsp;/ /g' \
        -e '/^[[:space:]]*$/d' "$1"
  fi
}

case "$content_type" in
  text/html|application/xhtml*)
    html_to_text "$tmp_raw" > "$tmp_text"
    ;;
  application/json)
    if command -v jq &>/dev/null; then
      jq '.' "$tmp_raw" > "$tmp_text" 2>/dev/null || cp "$tmp_raw" "$tmp_text"
    else
      cp "$tmp_raw" "$tmp_text"
    fi
    ;;
  *)
    # Plain text, markdown, XML, etc. — use as-is
    cp "$tmp_raw" "$tmp_text"
    ;;
esac

# Normalize whitespace for stable diffing
sed -i 's/[[:space:]]*$//' "$tmp_text"

# --- Compare against cache ------------------------------------------------
if [[ ! -f "$cache_file" ]]; then
  # First fetch — store cache, report as changed so LLM gets initial content
  cp "$tmp_text" "$cache_file"
  echo "$URL" > "$cache_meta"
  echo "## URL first fetch: $URL"
  echo ""
  echo "### Current content"
  echo ""
  cat "$tmp_text"
  exit 0
fi

if diff -q "$cache_file" "$tmp_text" &>/dev/null; then
  # No changes — exit 0 with empty stdout (precheck will skip LLM)
  exit 0
fi

# --- Changed! Output diff + both versions for LLM context ----------------
echo "## URL changed: $URL"
echo ""
echo "### Diff"
echo ""
echo '```diff'
diff -u "$cache_file" "$tmp_text" | head -200 || true
echo '```'
echo ""
echo "### Previous content"
echo ""
head -100 "$cache_file"
if [[ $(wc -l < "$cache_file") -gt 100 ]]; then
  echo ""
  echo "[... truncated at 100 lines ...]"
fi
echo ""
echo "### Current content"
echo ""
cat "$tmp_text"

# Update cache for next run
cp "$tmp_text" "$cache_file"
exit 0
