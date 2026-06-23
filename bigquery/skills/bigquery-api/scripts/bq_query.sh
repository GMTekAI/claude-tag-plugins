#!/usr/bin/env bash
# Copyright 2026 Anthropic PBC
# SPDX-License-Identifier: Apache-2.0
# run a bigquery sql query end-to-end with curl + jq: optional dry-run cost check, submit,
# poll until the job is done (location threaded through), page through every result page, and
# decode the {"f":[{"v":...}]} cell encoding into tsv or jsonl. generic to any bigquery
# project — everything instance-specific comes from env vars or flags.

set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  bq_query.sh [options] "SELECT ..."           # sql as a single quoted argument
  echo "SELECT ..." | bq_query.sh [options]    # sql on stdin

options:
  --param NAME=TYPE:VALUE  named query parameter, repeatable. TYPE is a scalar standard sql type
                           (STRING, INT64, FLOAT64, BOOL, DATE, TIMESTAMP, ...).
                           example: --param state=STRING:CA --param min_total=INT64:100
  --dry-run                report the bytes the query would scan, then exit without running it
  --max-gb N               fail the query instead of scanning more than N GiB (maximumBytesBilled)
  --max-rows N             stop fetching after N rows (default 10000; 0 = fetch everything)
  --max-wait SECONDS       give up waiting for the job after this long (default 600)
  --page-size N            rows per result page (default 1000)
  --project ID             billing project (defaults to $GCP_PROJECT)
  --json                   emit one json object per row (jsonl) instead of tsv
  -h, --help               show this help

environment:
  GCP_PROJECT  billing project id (required unless --project is given)
  BQ_TOKEN     bearer token; injected by the runtime, so the placeholder default is fine
  BQ_BASE_URL  api root override (default https://bigquery.googleapis.com/bigquery/v2)

output:
  rows on stdout — tsv with a header row by default, jsonl with --json. nested/repeated columns
  are emitted as raw json. job id, bytes scanned, warnings, and row counts go to stderr.

exit codes:
  0 success    1 request or query failed    2 timed out waiting (job id printed on stderr)
EOF
}

err() { printf '%s\n' "$*" >&2; }

command -v curl >/dev/null || { err "curl is required"; exit 1; }
command -v jq >/dev/null || { err "jq is required"; exit 1; }

BASE_URL="${BQ_BASE_URL:-https://bigquery.googleapis.com/bigquery/v2}"
TOKEN="${BQ_TOKEN:-placeholder}"
PROJECT="${GCP_PROJECT:-}"
DRY_RUN=false
MAX_GB=""
MAX_ROWS=10000
MAX_WAIT=600
PAGE_SIZE=1000
SYNC_TIMEOUT_MS=30000
FORMAT=tsv
PARAMS='[]'
SQL=""

# require_int FLAG VALUE — flags that take a count must get a non-negative integer
require_int() {
  case "$2" in
    ''|*[!0-9]*) err "$1 needs a non-negative integer, got '${2:-nothing}'"; exit 1 ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --param)
      SPEC="${2:-}"
      NAME="${SPEC%%=*}"
      REST="${SPEC#*=}"
      if [ -z "$NAME" ] || [ "$NAME" = "$SPEC" ] || [ "${REST#*:}" = "$REST" ]; then
        err "bad --param '$SPEC' (expected NAME=TYPE:VALUE, e.g. state=STRING:CA)"
        exit 1
      fi
      PTYPE="$(printf '%s' "${REST%%:*}" | tr '[:lower:]' '[:upper:]')"
      PVALUE="${REST#*:}"
      PARAMS="$(jq -c --arg n "$NAME" --arg t "$PTYPE" --arg v "$PVALUE" \
        '. + [{name: $n, parameterType: {type: $t}, parameterValue: {value: $v}}]' <<<"$PARAMS")"
      shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --max-gb)
      require_int --max-gb "${2:-}"
      if [ "$2" -lt 1 ]; then err "--max-gb must be at least 1"; exit 1; fi
      MAX_GB="$2"; shift 2 ;;
    --max-rows) require_int --max-rows "${2:-}"; MAX_ROWS="$2"; shift 2 ;;
    --max-wait) require_int --max-wait "${2:-}"; MAX_WAIT="$2"; shift 2 ;;
    --page-size) require_int --page-size "${2:-}"; PAGE_SIZE="$2"; shift 2 ;;
    --project)
      if [ -z "${2:-}" ]; then err "--project needs a project id"; exit 1; fi
      PROJECT="$2"; shift 2 ;;
    --json) FORMAT=json; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) err "unknown option: $1 (see --help)"; exit 1 ;;
    *)
      if [ -n "$SQL" ]; then
        err "unexpected extra argument: $1 (pass the sql as one quoted string)"; exit 1
      fi
      SQL="$1"; shift ;;
  esac
done

if [ -z "$SQL" ]; then
  if [ -t 0 ]; then err "no sql given (pass it as an argument or on stdin; see --help)"; exit 1; fi
  SQL="$(cat)"
fi
if [ -z "${SQL//[[:space:]]/}" ]; then err "no sql given"; exit 1; fi
if [ -z "$PROJECT" ]; then err "set GCP_PROJECT or pass --project"; exit 1; fi

MAX_BYTES=""
if [ -n "$MAX_GB" ]; then MAX_BYTES=$(( MAX_GB * 1073741824 )); fi

bq_api() {
  curl -sS --max-time 120 \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    "$@"
}

bq_urlencode() { jq -rn --arg s "$1" '$s | @uri'; }

# exit with the api's own message if the response is an error (or not json at all)
bq_check_error() {
  if ! jq -e . >/dev/null 2>&1 <<<"$1"; then
    err "non-json response from the api:"
    printf '%s\n' "$1" | head -c 2000 >&2
    exit 1
  fi
  if [ "$(jq -r 'type == "object" and has("error")' <<<"$1")" = "true" ]; then
    jq -r '"bigquery error \(.error.code // ""): \(.error.message // "unknown error")"' <<<"$1" >&2
    exit 1
  fi
}

BODY="$(jq -cn \
  --arg query "$SQL" \
  --argjson params "$PARAMS" \
  --argjson dryrun "$DRY_RUN" \
  --argjson timeout_ms "$SYNC_TIMEOUT_MS" \
  --argjson page_size "$PAGE_SIZE" \
  --arg max_bytes "$MAX_BYTES" \
  '{query: $query, useLegacySql: false, timeoutMs: $timeout_ms, maxResults: $page_size}
   + (if $dryrun then {dryRun: true} else {} end)
   + (if ($params | length) > 0 then {parameterMode: "NAMED", queryParameters: $params} else {} end)
   + (if $max_bytes != "" then {maximumBytesBilled: $max_bytes} else {} end)')"

RESP="$(bq_api -X POST "${BASE_URL}/projects/${PROJECT}/queries" -d "$BODY")"
bq_check_error "$RESP"

if [ "$DRY_RUN" = "true" ]; then
  jq -r '"dry run: would scan \(.totalBytesProcessed // "0") bytes" +
    " (~\(((.totalBytesProcessed // "0") | tonumber / 1073741824 * 100 | round) / 100) GiB)"
    ' <<<"$RESP"
  exit 0
fi

JOB_ID="$(jq -r '.jobReference.jobId // empty' <<<"$RESP")"
LOCATION="$(jq -r '.jobReference.location // empty' <<<"$RESP")"
COMPLETE="$(jq -r '.jobComplete // false' <<<"$RESP")"

if [ -n "$JOB_ID" ]; then err "job: ${JOB_ID}${LOCATION:+ (location: ${LOCATION})}"; fi

RESULTS_URL="${BASE_URL}/projects/${PROJECT}/queries/${JOB_ID}"
LOC_PARAM=""
if [ -n "$LOCATION" ]; then LOC_PARAM="&location=$(bq_urlencode "$LOCATION")"; fi

if [ "$COMPLETE" != "true" ] && [ -z "$JOB_ID" ]; then
  err "query did not complete and no job reference was returned — cannot poll"
  exit 1
fi

# poll getQueryResults (it long-polls up to timeoutMs per call) until the job completes
DEADLINE=$(( $(date +%s) + MAX_WAIT ))
while [ "$COMPLETE" != "true" ]; do
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    err "gave up after ${MAX_WAIT}s; job ${JOB_ID} is still running"
    err "poll it later: GET ${RESULTS_URL}?maxResults=${PAGE_SIZE}${LOC_PARAM}"
    exit 2
  fi
  sleep 2
  RESP="$(bq_api "${RESULTS_URL}?timeoutMs=10000&maxResults=${PAGE_SIZE}${LOC_PARAM}")"
  bq_check_error "$RESP"
  COMPLETE="$(jq -r '.jobComplete // false' <<<"$RESP")"
done

jq -r '"scanned \(.totalBytesProcessed // "0") bytes" +
  (if .cacheHit == true then " (cache hit)" else "" end) +
  ", total rows: \(.totalRows // "0")"' <<<"$RESP" >&2
jq -r '.errors[]? | "warning: \(.message // .)"' <<<"$RESP" >&2

# statements with no result schema (dml, ddl) — report what happened and stop
NUM_COLS="$(jq -r '.schema.fields // [] | length' <<<"$RESP")"
if [ "$NUM_COLS" = "0" ]; then
  DML_ROWS="$(jq -r '.numDmlAffectedRows // empty' <<<"$RESP")"
  if [ -n "$DML_ROWS" ]; then
    err "statement ok: ${DML_ROWS} rows affected"
  else
    err "statement ok: no result rows"
  fi
  exit 0
fi

COLS="$(jq -c '[.schema.fields[].name]' <<<"$RESP")"
if [ "$FORMAT" = "tsv" ]; then jq -r '[.schema.fields[].name] | @tsv' <<<"$RESP"; fi

# print up to $2 rows from page $1; cells are strings in the api, so only nested values need tojson
print_page() {
  if [ "$FORMAT" = "tsv" ]; then
    jq -r --argjson take "$2" \
      '[.rows[]?][:$take][]
       | [.f[].v | if type == "string" then . elif . == null then "" else tojson end]
       | @tsv' <<<"$1"
  else
    jq -c --argjson take "$2" --argjson cols "$COLS" \
      '[.rows[]?][:$take][]
       | [$cols, [.f[].v]] | transpose | map({(.[0]): .[1]}) | add' <<<"$1"
  fi
}

TOTAL="$(jq -r '.totalRows // "0"' <<<"$RESP")"
FETCHED=0
PAGE="$RESP"

while :; do
  COUNT="$(jq -r '[.rows[]?] | length' <<<"$PAGE")"
  TAKE="$COUNT"
  if [ "$MAX_ROWS" -gt 0 ]; then
    REMAINING=$(( MAX_ROWS - FETCHED ))
    if [ "$COUNT" -gt "$REMAINING" ]; then TAKE="$REMAINING"; fi
  fi
  if [ "$TAKE" -gt 0 ]; then print_page "$PAGE" "$TAKE"; fi
  FETCHED=$(( FETCHED + TAKE ))

  PT="$(jq -r '.pageToken // empty' <<<"$PAGE")"
  if [ "$MAX_ROWS" -gt 0 ] && [ "$FETCHED" -ge "$MAX_ROWS" ]; then
    if [ -n "$PT" ] || [ "$COUNT" -gt "$TAKE" ]; then
      err "output truncated at ${FETCHED} of ${TOTAL} rows (raise --max-rows, or 0 for everything)"
    fi
    break
  fi
  if [ -z "$PT" ]; then break; fi
  NEXT_URL="${RESULTS_URL}?maxResults=${PAGE_SIZE}${LOC_PARAM}&pageToken=$(bq_urlencode "$PT")"
  PAGE="$(bq_api "$NEXT_URL")"
  bq_check_error "$PAGE"
done

err "fetched ${FETCHED} of ${TOTAL} rows"
