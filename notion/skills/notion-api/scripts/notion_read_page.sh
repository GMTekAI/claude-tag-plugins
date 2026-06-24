#!/usr/bin/env bash
# Copyright 2026 Anthropic PBC
# SPDX-License-Identifier: Apache-2.0
# read a notion page's full body with curl + jq: walk the block tree depth-first, follow the
# start_cursor pagination at every level, decode each block's type-keyed payload to plain text,
# and emit tsv or jsonl. generic to any notion workspace — everything instance-specific comes
# from env vars or flags.

set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  notion_read_page.sh [options] PAGE_OR_BLOCK_ID

  the id is the 32-hex string at the end of a notion url, with or without dashes.

options:
  --max-depth N    recurse this many levels into nested blocks (default 8; 0 = top level only)
  --max-blocks N   stop after emitting N blocks total (default 2000; 0 = no cap)
  --page-size N    children per api page, max 100 (default 100)
  --json           emit one json object per block (jsonl) instead of tsv
  -h, --help       show this help

environment:
  NOTION_API_KEY   bearer token; injected by the runtime, so the placeholder default is fine
  NOTION_VERSION   api version header (default 2025-09-03)
  NOTION_BASE_URL  api root override (default https://api.notion.com/v1)

output:
  blocks on stdout in document order — tsv with header (depth, type, id, text) by default, or
  jsonl with --json ({depth, id, type, has_children, text}). child_page / child_database blocks
  are listed but not recursed into (they are separate pages — re-run with that id). request
  count and any truncation warning go to stderr.

exit codes:
  0 success; non-zero on failure (1 = api/argument error, other = curl transport error)
EOF
}

err() { printf '%s\n' "$*" >&2; }

command -v curl >/dev/null || { err "curl is required"; exit 1; }
command -v jq >/dev/null || { err "jq is required"; exit 1; }

BASE_URL="${NOTION_BASE_URL:-https://api.notion.com/v1}"
TOKEN="${NOTION_API_KEY:-placeholder}"
VERSION="${NOTION_VERSION:-2025-09-03}"
MAX_DEPTH=8
MAX_BLOCKS=2000
PAGE_SIZE=100
FORMAT=tsv
ROOT_ID=""

# require_int FLAG VALUE — flags that take a count must get a non-negative integer
require_int() {
  case "$2" in
    ''|*[!0-9]*) err "$1 needs a non-negative integer, got '${2:-nothing}'"; exit 1 ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --max-depth) require_int --max-depth "${2:-}"; MAX_DEPTH="$2"; shift 2 ;;
    --max-blocks) require_int --max-blocks "${2:-}"; MAX_BLOCKS="$2"; shift 2 ;;
    --page-size)
      require_int --page-size "${2:-}"
      if [ "$2" -lt 1 ] || [ "$2" -gt 100 ]; then err "--page-size must be 1..100"; exit 1; fi
      PAGE_SIZE="$2"; shift 2 ;;
    --json) FORMAT=json; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) err "unknown option: $1 (see --help)"; exit 1 ;;
    *)
      if [ -n "$ROOT_ID" ]; then err "unexpected extra argument: $1"; exit 1; fi
      ROOT_ID="$1"; shift ;;
  esac
done

if [ -z "$ROOT_ID" ]; then err "no page/block id given (see --help)"; exit 1; fi

notion_api() {
  curl -sS --max-time 60 \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Notion-Version: ${VERSION}" \
    "$@"
}

urlenc() { jq -rn --arg s "$1" '$s | @uri'; }

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

# pull readable text out of a block's type-keyed payload; covers the common shapes and falls
# back to a url for media blocks
read -r -d '' JQ_TEXT <<'EOF' || true
def blocktext:
  .[.type] as $p
  | ([$p.rich_text[]?.plain_text] | join("")) as $rt
  | if $rt != "" then $rt
    elif .type == "child_page" or .type == "child_database" then ($p.title // "")
    elif .type == "table_row" then
      ([$p.cells[]? | [.[]?.plain_text] | join("")] | join(" | "))
    elif ($p.caption? // []) != [] then ([$p.caption[]?.plain_text] | join(""))
    elif ($p.external?.url? // "") != "" then $p.external.url
    elif ($p.file?.url? // "") != "" then $p.file.url
    elif ($p.url? // "") != "" then $p.url
    elif ($p.expression? // "") != "" then $p.expression
    else "" end;
EOF

emit() {
  if [ "$FORMAT" = "tsv" ]; then
    jq -r --argjson d "$2" "$JQ_TEXT"'[$d, .type, .id, blocktext] | @tsv' <<<"$1"
  else
    jq -c --argjson d "$2" "$JQ_TEXT"'
      {depth: $d, id, type, has_children, text: blocktext}' <<<"$1"
  fi
}

REQS=0
EMITTED=0
TRUNCATED=false

walk() {
  local parent="$1" depth="$2" cursor="" page url more block id btype kids
  while :; do
    if [ "$MAX_BLOCKS" -gt 0 ] && [ "$EMITTED" -ge "$MAX_BLOCKS" ]; then
      TRUNCATED=true; return 0
    fi
    url="${BASE_URL}/blocks/${parent}/children?page_size=${PAGE_SIZE}"
    if [ -n "$cursor" ]; then url="${url}&start_cursor=$(urlenc "$cursor")"; fi
    page="$(notion_api "$url")"
    REQS=$(( REQS + 1 ))
    check_error "$page"

    while IFS= read -r block; do
      [ -n "$block" ] || continue
      if [ "$MAX_BLOCKS" -gt 0 ] && [ "$EMITTED" -ge "$MAX_BLOCKS" ]; then
        TRUNCATED=true; return 0
      fi
      emit "$block" "$depth"
      EMITTED=$(( EMITTED + 1 ))
      kids="$(jq -r '.has_children' <<<"$block")"
      btype="$(jq -r '.type' <<<"$block")"
      # child_page / child_database are separate documents — list them but don't descend
      if [ "$kids" = "true" ] && [ "$depth" -lt "$MAX_DEPTH" ] \
         && [ "$btype" != "child_page" ] && [ "$btype" != "child_database" ]; then
        id="$(jq -r '.id' <<<"$block")"
        walk "$id" $(( depth + 1 ))
      fi
    done < <(jq -c '.results[]?' <<<"$page")

    more="$(jq -r '.has_more // false' <<<"$page")"
    cursor="$(jq -r '.next_cursor // empty' <<<"$page")"
    if [ "$more" != "true" ] || [ -z "$cursor" ]; then break; fi
  done
}

if [ "$FORMAT" = "tsv" ]; then printf 'depth\ttype\tid\ttext\n'; fi

walk "$ROOT_ID" 0

err "fetched ${EMITTED} blocks in ${REQS} request(s)"
if [ "$TRUNCATED" = "true" ]; then
  err "output truncated at ${EMITTED} blocks (raise --max-blocks, or 0 for everything)"
fi
