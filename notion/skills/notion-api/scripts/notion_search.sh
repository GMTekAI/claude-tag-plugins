#!/usr/bin/env bash
# Copyright 2026 Anthropic PBC
# SPDX-License-Identifier: Apache-2.0
# search the notion workspace by title with curl + jq: post /search, follow start_cursor
# pagination, do the type-aware title extraction (page properties vs top-level title), and emit
# tsv or jsonl. generic to any notion workspace — everything instance-specific comes from env vars
# or flags.

set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  notion_search.sh [options] [QUERY]

  searches titles only (not body content) across every page/data source the integration can
  see. omit QUERY to list everything shared with the integration.

options:
  --type KIND      restrict results to "page" or "data_source" (default: both)
  --limit N        stop after N results total (default 100; 0 = everything)
  --page-size N    results per api page, max 100 (default 100)
  --json           emit one json object per result (jsonl) instead of tsv
  -h, --help       show this help

environment:
  NOTION_API_KEY   bearer token; injected by the runtime, so the placeholder default is fine
  NOTION_VERSION   api version header (default 2025-09-03)
  NOTION_BASE_URL  api root override (default https://api.notion.com/v1)

output:
  results on stdout, newest-edited first — tsv with header (id, type, title, url,
  last_edited_time) by default, or jsonl with --json. result count and any truncation warning
  go to stderr.

exit codes:
  0 success    1 request failed, api error, or bad arguments
EOF
}

err() { printf '%s\n' "$*" >&2; }

command -v curl >/dev/null || { err "curl is required"; exit 1; }
command -v jq >/dev/null || { err "jq is required"; exit 1; }

BASE_URL="${NOTION_BASE_URL:-https://api.notion.com/v1}"
TOKEN="${NOTION_API_KEY:-placeholder}"
VERSION="${NOTION_VERSION:-2025-09-03}"
LIMIT=100
PAGE_SIZE=100
FORMAT=tsv
TYPE=""
QUERY=""

# require_int FLAG VALUE — flags that take a count must get a non-negative integer
require_int() {
  case "$2" in
    ''|*[!0-9]*) err "$1 needs a non-negative integer, got '${2:-nothing}'"; exit 1 ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --type)
      case "${2:-}" in
        page|data_source) TYPE="$2"; shift 2 ;;
        *) err "--type must be 'page' or 'data_source', got '${2:-nothing}'"; exit 1 ;;
      esac ;;
    --limit) require_int --limit "${2:-}"; LIMIT="$2"; shift 2 ;;
    --page-size)
      require_int --page-size "${2:-}"
      if [ "$2" -lt 1 ] || [ "$2" -gt 100 ]; then err "--page-size must be 1..100"; exit 1; fi
      PAGE_SIZE="$2"; shift 2 ;;
    --json) FORMAT=json; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) err "unknown option: $1 (see --help)"; exit 1 ;;
    *)
      if [ -n "$QUERY" ]; then err "unexpected extra argument: $1"; exit 1; fi
      QUERY="$1"; shift ;;
  esac
done

notion_api() {
  curl -sS --max-time 60 \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Notion-Version: ${VERSION}" \
    -H "Content-Type: application/json" \
    "$@"
}

# exit with the api's own message if the response is an error envelope (or not json at all)
check_error() {
  if ! jq -e . >/dev/null 2>&1 <<<"$1"; then
    err "non-json response from the api:"
    printf '%s\n' "$1" | head -c 2000 >&2
    exit 1
  fi
  if [ "$(jq -r '.object == "error"' <<<"$1")" = "true" ]; then
    jq -r '"notion error \(.status // "") \(.code // ""): \(.message // "unknown error")"' \
      <<<"$1" >&2
    exit 1
  fi
}

# type-aware title extraction: a database-row page keeps its title under whichever property has
# type "title" (often "Name"); data_source results carry a top-level .title array instead
read -r -d '' JQ_TITLE <<'EOF' || true
def restitle:
  ((.properties // {}) | to_entries[]
    | select(.value.type? == "title") | .value.title[0]?.plain_text)
  // .title[0]?.plain_text // "(untitled)";
EOF

emit() {
  if [ "$FORMAT" = "tsv" ]; then
    jq -r --argjson take "$2" "$JQ_TITLE"'
      [.results[]?][:$take][]
      | [.id, .object, restitle, (.url // ""), (.last_edited_time // "")] | @tsv' <<<"$1"
  else
    jq -c --argjson take "$2" "$JQ_TITLE"'
      [.results[]?][:$take][]
      | {id, type: .object, title: restitle, url, last_edited_time}' <<<"$1"
  fi
}

build_body() {
  jq -cn \
    --arg q "$QUERY" \
    --arg t "$TYPE" \
    --arg cursor "$1" \
    --argjson page_size "$PAGE_SIZE" \
    '{sort: {direction: "descending", timestamp: "last_edited_time"}, page_size: $page_size}
     + (if $q != "" then {query: $q} else {} end)
     + (if $t != "" then {filter: {property: "object", value: $t}} else {} end)
     + (if $cursor != "" then {start_cursor: $cursor} else {} end)'
}

if [ "$FORMAT" = "tsv" ]; then printf 'id\ttype\ttitle\turl\tlast_edited_time\n'; fi

REQS=0
EMITTED=0
TRUNCATED=false
CURSOR=""

while :; do
  PAGE="$(notion_api -X POST "${BASE_URL}/search" -d "$(build_body "$CURSOR")")"
  REQS=$(( REQS + 1 ))
  check_error "$PAGE"

  COUNT="$(jq -r '[.results[]?] | length' <<<"$PAGE")"
  TAKE="$COUNT"
  if [ "$LIMIT" -gt 0 ]; then
    REMAINING=$(( LIMIT - EMITTED ))
    if [ "$COUNT" -gt "$REMAINING" ]; then TAKE="$REMAINING"; fi
  fi
  if [ "$TAKE" -gt 0 ]; then emit "$PAGE" "$TAKE"; fi
  EMITTED=$(( EMITTED + TAKE ))

  MORE="$(jq -r '.has_more // false' <<<"$PAGE")"
  CURSOR="$(jq -r '.next_cursor // empty' <<<"$PAGE")"
  if [ "$LIMIT" -gt 0 ] && [ "$EMITTED" -ge "$LIMIT" ]; then
    if [ "$MORE" = "true" ] || [ "$COUNT" -gt "$TAKE" ]; then TRUNCATED=true; fi
    break
  fi
  if [ "$MORE" != "true" ] || [ -z "$CURSOR" ]; then break; fi
done

err "fetched ${EMITTED} result(s) in ${REQS} request(s)"
if [ "$TRUNCATED" = "true" ]; then
  err "output truncated at ${EMITTED} results (raise --limit, or 0 for everything)"
fi
