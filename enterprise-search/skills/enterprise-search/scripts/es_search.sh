#!/usr/bin/env bash
# Copyright 2026 Anthropic PBC
# SPDX-License-Identifier: Apache-2.0
# search the enterprise knowledge index with curl + jq: post /rest/api/v1/search, follow
# cursor pagination, and emit one row per ranked result. speaks the glean client api dialect —
# works against real glean or any glean-compatible backend; everything instance-specific comes
# from env vars or flags.

set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  es_search.sh [options] "QUERY"

  searches the enterprise knowledge index across all connected sources. results are ranked
  best-first; the snippet column is a short match preview for triage, not for answering.

options:
  --datasource NAME  restrict results to one source app (slack, gdrive, github, ...).
                     repeatable; multiple values are OR'd.
  --limit N          stop after N results total (default 10, max 100)
  --page-size N      results per api page (default: same as --limit, max 100)
  --json             emit one json object per result (jsonl) instead of tsv; includes
                     trackingToken fields needed for feedback
  -h, --help         show this help

environment:
  GLEAN_BASE_URL   instance api root, e.g. https://company-be.glean.com (required)
  GLEAN_API_TOKEN  bearer token; injected by the runtime, so the placeholder default is fine

output:
  results on stdout, ranked best-first — tsv with header (rank, title, url, datasource,
  doc_id, snippet) by default, or jsonl with --json. the search-level trackingToken, result
  count, and any truncation warning go to stderr.

exit codes:
  0 success    1 request failed, api error, or bad arguments
EOF
}

err() { printf '%s\n' "$*" >&2; }

command -v curl >/dev/null || { err "curl is required"; exit 1; }
command -v jq >/dev/null || { err "jq is required"; exit 1; }

BASE_URL="${GLEAN_BASE_URL:-}"
TOKEN="${GLEAN_API_TOKEN:-placeholder}"
LIMIT=10
PAGE_SIZE=""
FORMAT=tsv
DATASOURCES='[]'
QUERY=""

# require_int FLAG VALUE — flags that take a count must get a non-negative integer
require_int() {
  case "$2" in
    ''|*[!0-9]*) err "$1 needs a non-negative integer, got '${2:-nothing}'"; exit 1 ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --datasource)
      [ -n "${2:-}" ] || { err "--datasource needs a value"; exit 1; }
      DATASOURCES=$(jq -cn --argjson cur "$DATASOURCES" --arg d "$2" '$cur + [$d]')
      shift 2 ;;
    --limit)
      require_int --limit "${2:-}"
      if [ "$2" -lt 1 ] || [ "$2" -gt 100 ]; then err "--limit must be 1..100"; exit 1; fi
      LIMIT="$2"; shift 2 ;;
    --page-size)
      require_int --page-size "${2:-}"
      if [ "$2" -lt 1 ] || [ "$2" -gt 100 ]; then err "--page-size must be 1..100"; exit 1; fi
      PAGE_SIZE="$2"; shift 2 ;;
    --json) FORMAT=json; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; [ -n "${1:-}" ] && QUERY="$1"; break ;;
    -*) err "unknown option: $1 (see --help)"; exit 1 ;;
    *)
      if [ -n "$QUERY" ]; then err "unexpected extra argument: $1"; exit 1; fi
      QUERY="$1"; shift ;;
  esac
done

[ -n "$QUERY" ] || { err "a search query is required (see --help)"; exit 1; }
[ -n "$BASE_URL" ] || { err "GLEAN_BASE_URL is not set"; exit 1; }
BASE_URL="${BASE_URL%/}"
[ -z "$PAGE_SIZE" ] && PAGE_SIZE="$LIMIT"

# one api call per loop iteration; cursor pagination until the limit or the last page
fetched=0
cursor=""
search_token=""
[ "$FORMAT" = tsv ] && printf 'rank\ttitle\turl\tdatasource\tdoc_id\tsnippet\n'

while :; do
  remaining=$((LIMIT - fetched))
  [ "$remaining" -le 0 ] && break
  size=$((remaining < PAGE_SIZE ? remaining : PAGE_SIZE))

  body=$(jq -cn \
    --arg q "$QUERY" --argjson size "$size" --arg cursor "$cursor" --argjson ds "$DATASOURCES" '
    {
      query: $q,
      pageSize: $size,
      requestOptions: ({facetBucketSize: 10}
        + (if ($ds | length) > 0 then {datasourcesFilter: $ds} else {} end))
    }
    + (if $cursor != "" then {cursor: $cursor} else {} end)
  ')

  resp=$(curl -sS --max-time 60 -w '\n%{http_code}' "${BASE_URL}/rest/api/v1/search" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$body") || { err "request failed"; exit 1; }

  status=$(printf '%s' "$resp" | tail -n1)
  payload=$(printf '%s' "$resp" | sed '$d')

  if [ "$status" -lt 200 ] || [ "$status" -ge 300 ]; then
    msg=$(printf '%s' "$payload" \
      | jq -r '.detail // .errorMessage // .' 2>/dev/null || printf '%s' "$payload")
    err "api error (http $status): $msg"
    exit 1
  fi

  if [ -z "$search_token" ]; then
    search_token=$(printf '%s' "$payload" | jq -r '.trackingToken // empty')
    [ -n "$search_token" ] && err "search trackingToken: $search_token"
  fi

  count=$(printf '%s' "$payload" | jq '.results | length')
  [ "$count" -eq 0 ] && break

  if [ "$FORMAT" = json ]; then
    printf '%s' "$payload" | jq -c --argjson base "$fetched" '
      .results | to_entries[] | {
        rank: ($base + .key + 1),
        title: .value.title,
        url: .value.url,
        datasource: (.value.document.datasource // ""),
        doc_id: (.value.document.id // ""),
        snippet: (.value.snippets[0].snippet // .value.snippets[0].text // ""),
        trackingToken: .value.trackingToken
      }'
  else
    printf '%s' "$payload" | jq -r --argjson base "$fetched" '
      .results | to_entries[] | [
        ($base + .key + 1),
        (.value.title // "" | gsub("[\t\n]"; " ")),
        (.value.url // ""),
        (.value.document.datasource // ""),
        (.value.document.id // ""),
        (.value.snippets[0].snippet // .value.snippets[0].text // "" | gsub("[\t\n]"; " "))
      ] | @tsv'
  fi

  fetched=$((fetched + count))
  has_more=$(printf '%s' "$payload" | jq -r '.hasMoreResults // false')
  cursor=$(printf '%s' "$payload" | jq -r '.cursor // empty')
  { [ "$has_more" != "true" ] || [ -z "$cursor" ]; } && break
done

err "$fetched result(s)"
if [ "$fetched" -ge "$LIMIT" ] && [ "${has_more:-false}" = "true" ] && [ -n "$cursor" ]; then
  err "warning: hit --limit $LIMIT; more results may exist (raise --limit to see them)"
fi
