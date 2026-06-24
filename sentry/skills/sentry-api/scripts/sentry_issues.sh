#!/usr/bin/env bash
# Copyright 2026 Anthropic PBC
# SPDX-License-Identifier: Apache-2.0
# search sentry issues across the org with curl + jq: build the query with -G --data-urlencode,
# resolve project slugs to numeric ids for robustness across older self-hosted versions, follow the
# link-header cursor through every page, surface the {"detail":...} error body, and emit tsv or
# jsonl. generic to any sentry install — everything instance-specific comes from env vars
# or flags.

set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  sentry_issues.sh [options] "is:unresolved level:error"   # query as one quoted argument
  echo "release:2.3.1" | sentry_issues.sh [options]        # query on stdin
  sentry_issues.sh [options]                               # defaults to "is:unresolved"

options:
  --project VALUE      scope to a project; numeric id or slug (slugs are resolved to ids for
                       robustness across older self-hosted versions). repeatable.
  --sort FIELD         date | new | freq | user | trends | inbox | recommended
  --period PERIOD      statsPeriod, e.g. 24h, 7d, 14d
  --environment NAME   scope to an environment. repeatable.
  --limit N            stop after N issues total (default 100; 0 = fetch everything)
  --json               emit one json object per issue (jsonl) instead of tsv
  -h, --help           show this help

environment:
  SENTRY_URL    api root (default https://sentry.io; self-hosted: https://sentry.example.com)
  SENTRY_ORG    organization slug (required)
  SENTRY_TOKEN  bearer token; injected by the runtime, so the placeholder default is fine

output:
  issues on stdout — tsv with header (shortId, title, culprit, count, userCount, lastSeen,
  permalink) by default, jsonl with --json (the full issue object per line). request count and
  any truncation warning go to stderr.

exit codes:
  0 success    1 request failed, api error, or bad arguments
EOF
}

err() { printf '%s\n' "$*" >&2; }

command -v curl >/dev/null || { err "curl is required"; exit 1; }
command -v jq >/dev/null || { err "jq is required"; exit 1; }

BASE_URL="${SENTRY_URL:-https://sentry.io}"
BASE_URL="${BASE_URL%/}"
TOKEN="${SENTRY_TOKEN:-placeholder}"
ORG="${SENTRY_ORG:-}"
LIMIT=100
FORMAT=tsv
SORT=""
PERIOD=""
QUERY=""
PROJECT_RAW=()
ENVS=()
MAX_PAGES=1000

# require_int FLAG VALUE — flags that take a count must get a non-negative integer
require_int() {
  case "$2" in
    ''|*[!0-9]*) err "$1 needs a non-negative integer, got '${2:-nothing}'"; exit 1 ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ -n "${2:-}" ] || { err "--project needs a numeric id or slug"; exit 1; }
      PROJECT_RAW+=("$2"); shift 2 ;;
    --sort)
      case "${2:-}" in
        date|new|freq|user|trends|inbox|recommended) SORT="$2"; shift 2 ;;
        *) err "--sort must be one of: date new freq user trends inbox recommended"; exit 1 ;;
      esac ;;
    --period)
      [ -n "${2:-}" ] || { err "--period needs a value like 24h or 14d"; exit 1; }
      PERIOD="$2"; shift 2 ;;
    --environment)
      [ -n "${2:-}" ] || { err "--environment needs a name"; exit 1; }
      ENVS+=("$2"); shift 2 ;;
    --limit) require_int --limit "${2:-}"; LIMIT="$2"; shift 2 ;;
    --json) FORMAT=json; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) err "unknown option: $1 (see --help)"; exit 1 ;;
    *)
      if [ -n "$QUERY" ]; then
        err "unexpected extra argument: $1 (pass the query as one quoted string)"; exit 1
      fi
      QUERY="$1"; shift ;;
  esac
done

if [ -z "$QUERY" ] && [ ! -t 0 ]; then QUERY="$(cat)"; fi
if [ -z "${QUERY//[[:space:]]/}" ]; then QUERY="is:unresolved"; fi
[ -n "$ORG" ] || { err "set SENTRY_ORG to your organization slug"; exit 1; }

sentry_api() {
  curl -sS --max-time 60 -H "Authorization: Bearer ${TOKEN}" "$@"
}

# exit with the api's own message if the response is the error envelope (or not json at all)
sentry_check_error() {
  if ! jq -e . >/dev/null 2>&1 <<<"$1"; then
    err "non-json response from the api:"
    printf '%s\n' "$1" | head -c 2000 >&2
    exit 1
  fi
  if [ "$(jq -r 'type == "object" and has("detail")' <<<"$1")" = "true" ]; then
    jq -r '"sentry error: \(.detail // "unknown error")"' <<<"$1" >&2
    exit 1
  fi
}

HDR="$(mktemp)"
trap 'rm -f "$HDR"' EXIT

# resolve any non-numeric --project values (slugs) to numeric ids for robustness
PROJECT_IDS=()
for raw in "${PROJECT_RAW[@]+"${PROJECT_RAW[@]}"}"; do
  case "$raw" in
    *[!0-9]*)
      RESP="$(sentry_api "${BASE_URL}/api/0/projects/${ORG}/${raw}/")"
      if ! jq -e . >/dev/null 2>&1 <<<"$RESP"; then
        err "non-json response resolving project '${raw}':"
        printf '%s\n' "$RESP" | head -c 2000 >&2
        exit 1
      fi
      if [ "$(jq -r 'type == "object" and has("detail")' <<<"$RESP")" = "true" ]; then
        DETAIL="$(jq -r '.detail // "unknown error"' <<<"$RESP")"
        err "no project with slug '${raw}' in org '${ORG}': ${DETAIL}"
        exit 1
      fi
      ID="$(jq -r '.id // empty' <<<"$RESP")"
      if [ -z "$ID" ]; then
        err "no project with slug '${raw}' in org '${ORG}' (no id in response)"
        exit 1
      fi
      err "project ${raw} -> id ${ID}"
      PROJECT_IDS+=("$ID") ;;
    *) PROJECT_IDS+=("$raw") ;;
  esac
done

# per-page cap is 100; ask for less when the total limit is smaller
PAGE_SIZE=100
if [ "$LIMIT" -gt 0 ] && [ "$LIMIT" -lt 100 ]; then PAGE_SIZE="$LIMIT"; fi

PARAMS=(--data-urlencode "query=${QUERY}" --data-urlencode "limit=${PAGE_SIZE}")
[ -n "$SORT" ] && PARAMS+=(--data-urlencode "sort=${SORT}")
[ -n "$PERIOD" ] && PARAMS+=(--data-urlencode "statsPeriod=${PERIOD}")
for p in "${PROJECT_IDS[@]+"${PROJECT_IDS[@]}"}"; do PARAMS+=(--data-urlencode "project=${p}"); done
for e in "${ENVS[@]+"${ENVS[@]}"}"; do PARAMS+=(--data-urlencode "environment=${e}"); done

if [ "$FORMAT" = "tsv" ]; then
  printf 'shortId\ttitle\tculprit\tcount\tuserCount\tlastSeen\tpermalink\n'
fi

# extract the rel="next" url from the Link header dump iff its results="true"
next_link() {
  local line re='<([^>]*)>;[[:space:]]*rel="next";[[:space:]]*results="true"'
  line="$(tr -d '\r' < "$1" | grep -i '^link:' || true)"
  if [[ "$line" =~ $re ]]; then printf '%s' "${BASH_REMATCH[1]}"; fi
}

FETCHED=0
PAGES=0
URL="${BASE_URL}/api/0/organizations/${ORG}/issues/"

while :; do
  if [ "$PAGES" -eq 0 ]; then
    BODY="$(sentry_api -G -D "$HDR" "$URL" "${PARAMS[@]}")"
  else
    # follow the rel="next" url verbatim — it already carries every query param + cursor
    BODY="$(sentry_api -D "$HDR" "$URL")"
  fi
  PAGES=$(( PAGES + 1 ))
  sentry_check_error "$BODY"

  COUNT="$(jq -r 'length' <<<"$BODY")"
  TAKE="$COUNT"
  if [ "$LIMIT" -gt 0 ]; then
    REMAINING=$(( LIMIT - FETCHED ))
    if [ "$COUNT" -gt "$REMAINING" ]; then TAKE="$REMAINING"; fi
  fi
  if [ "$TAKE" -gt 0 ]; then
    if [ "$FORMAT" = "tsv" ]; then
      jq -r --argjson take "$TAKE" '.[:$take][]
        | [.shortId, .title, .culprit, .count, .userCount, .lastSeen, .permalink]
        | map(if . == null then "" elif type == "object" or type == "array" then tojson
              else tostring end) | @tsv' <<<"$BODY"
    else
      jq -c --argjson take "$TAKE" '.[:$take][]' <<<"$BODY"
    fi
  fi
  FETCHED=$(( FETCHED + TAKE ))

  NEXT="$(next_link "$HDR")"
  if [ "$LIMIT" -gt 0 ] && [ "$FETCHED" -ge "$LIMIT" ]; then
    if [ -n "$NEXT" ] || [ "$COUNT" -gt "$TAKE" ]; then
      err "output truncated at ${FETCHED} issues (raise --limit, or 0 for everything)"
    fi
    break
  fi
  [ -n "$NEXT" ] || break
  if [ "$PAGES" -ge "$MAX_PAGES" ]; then
    err "stopped after ${MAX_PAGES} pages (safety cap)"; break
  fi
  # the Link header carries an absolute url; pin it to the configured sentry host so a
  # compromised response can't redirect the bearer token elsewhere.
  case "$NEXT" in
    "${BASE_URL}/"*) ;;
    *) err "refusing to follow off-host pagination url: $NEXT"; exit 1 ;;
  esac
  URL="$NEXT"
done

err "fetched ${FETCHED} issue(s) in ${PAGES} request(s)"
