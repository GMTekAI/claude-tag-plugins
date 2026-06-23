#!/usr/bin/env bash
# Copyright 2026 Anthropic PBC
# SPDX-License-Identifier: Apache-2.0
# run a salesforce soql query end-to-end with curl + jq: submit, follow nextRecordsUrl through
# every page, surface the array-shaped error body, strip the per-record "attributes" envelope,
# flatten parent-relationship objects to dotted keys, and emit tsv or jsonl. generic to any
# salesforce org — everything instance-specific comes from env vars or flags.

set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  sf_query.sh [options] "SELECT ..."           # soql as a single quoted argument
  echo "SELECT ..." | sf_query.sh [options]    # soql on stdin

options:
  --all                include deleted/archived records (queryAll instead of query)
  --max-rows N         stop fetching after N rows (default 10000; 0 = fetch everything)
  --batch-size N       rows per page, 200-2000 (Sforce-Query-Options header; default: server)
  --json               emit one json object per row (jsonl) instead of tsv
  --instance-url URL   org instance url (defaults to $SALESFORCE_INSTANCE_URL)
  --api-version VER    api version segment (defaults to $SALESFORCE_API_VERSION or v66.0)
  -h, --help           show this help

environment:
  SALESFORCE_INSTANCE_URL   org my-domain url, e.g. https://yourorg.my.salesforce.com (required)
  SALESFORCE_ACCESS_TOKEN   bearer token; injected by the runtime, placeholder default is fine
  SALESFORCE_API_VERSION    api version segment (default v66.0)

output:
  rows on stdout — tsv with a header row by default, jsonl with --json. parent-relationship
  fields (Account.Name) are flattened to dotted-key columns; child-subquery results and other
  nested values are emitted as json. totalSize and row counts go to stderr.

exit codes:
  0 success    1 request or query failed (errorCode and message on stderr)
EOF
}

err() { printf '%s\n' "$*" >&2; }

command -v curl >/dev/null || { err "curl is required"; exit 1; }
command -v jq >/dev/null || { err "jq is required"; exit 1; }

TOKEN="${SALESFORCE_ACCESS_TOKEN:-placeholder}"
INSTANCE_URL="${SALESFORCE_INSTANCE_URL:-}"
API_VERSION="${SALESFORCE_API_VERSION:-v66.0}"
ENDPOINT="query"
MAX_ROWS=10000
BATCH_SIZE=""
FORMAT=tsv
SOQL=""

# require_int FLAG VALUE — flags that take a count must get a non-negative integer
require_int() {
  case "$2" in
    ''|*[!0-9]*) err "$1 needs a non-negative integer, got '${2:-nothing}'"; exit 1 ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --all) ENDPOINT="queryAll"; shift ;;
    --max-rows) require_int --max-rows "${2:-}"; MAX_ROWS="$2"; shift 2 ;;
    --batch-size)
      require_int --batch-size "${2:-}"
      if [ "$2" -lt 200 ] || [ "$2" -gt 2000 ]; then
        err "--batch-size must be between 200 and 2000"; exit 1
      fi
      BATCH_SIZE="$2"; shift 2 ;;
    --json) FORMAT=json; shift ;;
    --instance-url)
      if [ -z "${2:-}" ]; then err "--instance-url needs a url"; exit 1; fi
      INSTANCE_URL="$2"; shift 2 ;;
    --api-version)
      if [ -z "${2:-}" ]; then err "--api-version needs a value like v66.0"; exit 1; fi
      API_VERSION="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) err "unknown option: $1 (see --help)"; exit 1 ;;
    *)
      if [ -n "$SOQL" ]; then
        err "unexpected extra argument: $1 (pass the soql as one quoted string)"; exit 1
      fi
      SOQL="$1"; shift ;;
  esac
done

if [ -z "$SOQL" ]; then
  if [ -t 0 ]; then
    err "no soql given (pass it as an argument or on stdin; see --help)"; exit 1
  fi
  SOQL="$(cat)"
fi
if [ -z "${SOQL//[[:space:]]/}" ]; then err "no soql given"; exit 1; fi
if [ -z "$INSTANCE_URL" ]; then
  err "set SALESFORCE_INSTANCE_URL or pass --instance-url"; exit 1
fi
INSTANCE_URL="${INSTANCE_URL%/}"
# the bearer token goes wherever this url points, so pin it to a salesforce
# domain before any curl call. [A-Za-z0-9.-]+ keeps / @ ? # out of the host so
# https://evil.com/x.salesforce.com and userinfo tricks don't slip through.
if ! printf '%s' "$INSTANCE_URL" \
     | grep -Eq '^https://[A-Za-z0-9.-]+\.(salesforce|force)\.com(:[0-9]+)?$'; then
  err "--instance-url must be an https Salesforce domain (*.salesforce.com or *.force.com)"
  exit 1
fi

sf_api() {
  if [ -n "$BATCH_SIZE" ]; then
    set -- -H "Sforce-Query-Options: batchSize=${BATCH_SIZE}" "$@"
  fi
  curl -sS --max-time 120 \
    -H "Authorization: Bearer ${TOKEN}" -H "Accept: application/json" "$@"
}

# salesforce returns errors as a top-level json array; success is an object. surface errorCode.
sf_check_error() {
  if ! jq -e . >/dev/null 2>&1 <<<"$1"; then
    err "non-json response from the api:"
    printf '%s\n' "$1" | head -c 2000 >&2
    exit 1
  fi
  if [ "$(jq -r 'type' <<<"$1")" = "array" ]; then
    jq -r '.[] | "salesforce error \(.errorCode // "?"): \(.message // "unknown error")"' \
      <<<"$1" >&2
    exit 1
  fi
}

# jq defs: drop .attributes; flatten parent-relationship objects (have .attributes, no .records)
# to dotted keys; reduce child-subquery objects (have .records) to a cleaned array.
read -r -d '' FLATTEN <<'JQ' || true
def clean:
  if type == "object" then
    with_entries(select(.key != "attributes") | .value |= clean)
  elif type == "array" then map(clean)
  else . end;
def flat:
  to_entries
  | map(select(.key != "attributes"))
  | map(
      if (.value | type) == "object" and (.value | has("records")) then
        {key, value: [.value.records[]? | clean]}
      elif (.value | type) == "object" and (.value | has("attributes")) then
        .key as $k | (.value | flat | to_entries | map(.key = $k + "." + .key))[]
      else . end)
  | from_entries;
JQ

PAGE="$(sf_api -G "${INSTANCE_URL}/services/data/${API_VERSION}/${ENDPOINT}" \
  --data-urlencode "q=${SOQL}")"
sf_check_error "$PAGE"

TOTAL="$(jq -r '.totalSize // 0' <<<"$PAGE")"
err "totalSize: ${TOTAL}"

COLS=""
FETCHED=0

while :; do
  COUNT="$(jq -r '.records | length' <<<"$PAGE")"
  TAKE="$COUNT"
  if [ "$MAX_ROWS" -gt 0 ]; then
    REMAINING=$(( MAX_ROWS - FETCHED ))
    if [ "$COUNT" -gt "$REMAINING" ]; then TAKE="$REMAINING"; fi
  fi

  if [ "$TAKE" -gt 0 ]; then
    if [ "$FORMAT" = "json" ]; then
      jq -c --argjson take "$TAKE" "${FLATTEN} .records[:\$take][] | flat" <<<"$PAGE"
    else
      if [ -z "$COLS" ]; then
        # column set = first-seen order of flattened keys across the first page
        COLS="$(jq -c "${FLATTEN}"'
          reduce (.records[] | flat | keys_unsorted[]) as $k
            ([]; if index($k) then . else . + [$k] end)' <<<"$PAGE")"
        jq -rn --argjson c "$COLS" '$c | @tsv'
      fi
      jq -r --argjson take "$TAKE" --argjson cols "$COLS" "${FLATTEN}"'
        .records[:$take][] | flat as $r
        | [$cols[] | $r[.]
           | if type == "object" or type == "array" then tojson
             elif . == null then "" else tostring end]
        | @tsv' <<<"$PAGE"
    fi
  fi
  FETCHED=$(( FETCHED + TAKE ))

  DONE="$(jq -r '.done' <<<"$PAGE")"
  NEXT="$(jq -r '.nextRecordsUrl // empty' <<<"$PAGE")"
  if [ "$MAX_ROWS" -gt 0 ] && [ "$FETCHED" -ge "$MAX_ROWS" ]; then
    if [ "$DONE" != "true" ] || [ "$COUNT" -gt "$TAKE" ]; then
      err "output truncated at ${FETCHED} of ${TOTAL} rows (raise --max-rows, or 0 for all)"
    fi
    break
  fi
  if [ "$DONE" = "true" ] || [ -z "$NEXT" ]; then break; fi
  # nextRecordsUrl is a full path under the instance url — do not prefix the api version again.
  # require a leading / so a compromised response can't redirect the bearer token off-host.
  case "$NEXT" in
    /*) ;;
    *) err "refusing to follow non-relative nextRecordsUrl: $NEXT"; exit 1 ;;
  esac
  PAGE="$(sf_api "${INSTANCE_URL}${NEXT}")"
  sf_check_error "$PAGE"
done

err "fetched ${FETCHED} of ${TOTAL} rows"
