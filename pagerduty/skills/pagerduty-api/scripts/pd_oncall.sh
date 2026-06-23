#!/usr/bin/env bash
# Copyright 2026 Anthropic PBC
# SPDX-License-Identifier: Apache-2.0
# answer "who is on call" via the pagerduty rest api with curl + jq: resolve service/user names
# to ids, query /oncalls with bracketed array filters (-g so curl doesn't glob them), page on
# offset/limit while more==true, and emit tsv or jsonl. generic to any pagerduty account —
# everything instance-specific comes from env vars or flags.

set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  pd_oncall.sh [options]

options:
  --service NAME|ID  scope to a service. a value matching ^P[A-Z0-9]{5,7}$ is used as the id;
                     anything else is resolved via /services?query=. the service's escalation
                     policy is then passed as escalation_policy_ids[] (the /oncalls endpoint
                     has no service filter)
  --policy ID        filter to an escalation policy id (repeatable -> escalation_policy_ids[])
  --schedule ID      filter to a schedule id (repeatable -> schedule_ids[])
  --user QUERY       filter to a user; resolved via /users?query= to ids (repeatable -> user_ids[])
  --at TIME          on-call at this iso-8601 instant (sets both since= and until=)
  --earliest         only the next-up entry per escalation policy (earliest=true)
  --limit N          stop after N entries total (default 100; 0 = fetch everything)
  --page-size N      entries per api page, max 100 (default 100)
  --json             emit one json object per entry (jsonl) instead of tsv
  -h, --help         show this help

environment:
  PAGERDUTY_TOKEN     api token; injected by the runtime, so the placeholder default is fine
  PAGERDUTY_BASE_URL  api root override (default https://api.pagerduty.com)

output:
  on-call entries on stdout — tsv with header (level, user, policy, schedule, until) by default,
  jsonl with --json. resolved ids, request count, and any truncation warning go to stderr.

exit codes:
  0 success    1 request failed, api error, or bad arguments
EOF
}

err() { printf '%s\n' "$*" >&2; }

command -v curl >/dev/null || { err "curl is required"; exit 1; }
command -v jq >/dev/null || { err "jq is required"; exit 1; }

BASE_URL="${PAGERDUTY_BASE_URL:-https://api.pagerduty.com}"
TOKEN="${PAGERDUTY_TOKEN:-placeholder}"
SERVICE=""
POLICY_IDS=()
SCHEDULE_IDS=()
USER_QUERIES=()
AT=""
EARLIEST=false
LIMIT=100
PAGE_SIZE=100
FORMAT=tsv

# require_int FLAG VALUE — flags that take a count must get a non-negative integer
require_int() {
  case "$2" in
    ''|*[!0-9]*) err "$1 needs a non-negative integer, got '${2:-nothing}'"; exit 1 ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --service)
      [ -n "${2:-}" ] || { err "--service needs a name or id"; exit 1; }
      SERVICE="$2"; shift 2 ;;
    --policy)
      [ -n "${2:-}" ] || { err "--policy needs an id"; exit 1; }
      POLICY_IDS+=("$2"); shift 2 ;;
    --schedule)
      [ -n "${2:-}" ] || { err "--schedule needs an id"; exit 1; }
      SCHEDULE_IDS+=("$2"); shift 2 ;;
    --user)
      [ -n "${2:-}" ] || { err "--user needs a name or email"; exit 1; }
      USER_QUERIES+=("$2"); shift 2 ;;
    --at)
      [ -n "${2:-}" ] || { err "--at needs an iso-8601 timestamp"; exit 1; }
      AT="$2"; shift 2 ;;
    --earliest) EARLIEST=true; shift ;;
    --limit) require_int --limit "${2:-}"; LIMIT="$2"; shift 2 ;;
    --page-size)
      require_int --page-size "${2:-}"
      if [ "$2" -lt 1 ] || [ "$2" -gt 100 ]; then err "--page-size must be 1..100"; exit 1; fi
      PAGE_SIZE="$2"; shift 2 ;;
    --json) FORMAT=json; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) err "unknown option: $1 (see --help)"; exit 1 ;;
    *) err "unexpected extra argument: $1 (see --help)"; exit 1 ;;
  esac
done

BASE_URL="${BASE_URL%/}"

# -g: pagerduty's bracketed array params (escalation_policy_ids[]=) trip curl globbing otherwise.
# -w appends the http status on its own line so callers can split it off — a 401 body is empty.
pd_api() {
  curl -sS -g --max-time 60 \
    -H "Authorization: Token token=${TOKEN}" \
    -H "Accept: application/vnd.pagerduty+json;version=2" \
    -w '\n%{http_code}' "$@"
}

# fail with the api's own message. $1 = body, $2 = http status.
pd_check() {
  if [ "${2:-0}" -ge 400 ] && [ -z "${1//[[:space:]]/}" ]; then
    err "pagerduty error: http ${2} (empty body)"; exit 1
  fi
  if ! jq -e . >/dev/null 2>&1 <<<"$1"; then
    err "non-json response from the api (http ${2:-?}):"
    printf '%s\n' "$1" | head -c 2000 >&2
    exit 1
  fi
  if [ "$(jq -r 'type == "object" and has("error")' <<<"$1")" = "true" ]; then
    jq -r '"pagerduty error \(.error.code // ""): \(.error.message // "unknown error")"
           + (if (.error.errors // [] | length) > 0
              then " — " + (.error.errors | join("; ")) else "" end)' <<<"$1" >&2
    exit 1
  fi
}

# resolve --service: id-shaped values used as-is, anything else looked up by name; the
# service's escalation policy id is what /oncalls actually filters on.
if [ -n "$SERVICE" ]; then
  if [[ "$SERVICE" =~ ^P[A-Z0-9]{5,7}$ ]]; then
    SVC_ID="$SERVICE"
  else
    RESP="$(pd_api -G "${BASE_URL}/services" --data-urlencode "query=${SERVICE}" \
      --data-urlencode "limit=2")"
    CODE="${RESP##*$'\n'}"; BODY="${RESP%$'\n'*}"
    pd_check "$BODY" "$CODE"
    N="$(jq -r '.services | length' <<<"$BODY")"
    if [ "$N" -eq 0 ]; then
      err "no service matched query '${SERVICE}'"; exit 1
    fi
    if [ "$N" -ge 2 ]; then
      CANDS="$(jq -r '.services[:2][] | "  \(.id)  \(.summary)"' <<<"$BODY")"
      err "multiple services match '${SERVICE}'; pass the id directly. candidates:"
      err "$CANDS"
      exit 1
    fi
    SVC_ID="$(jq -r '.services[0].id' <<<"$BODY")"
    err "service '${SERVICE}' -> ${SVC_ID}"
  fi
  RESP="$(pd_api "${BASE_URL}/services/${SVC_ID}")"
  CODE="${RESP##*$'\n'}"; BODY="${RESP%$'\n'*}"
  pd_check "$BODY" "$CODE"
  EP_ID="$(jq -r '.service.escalation_policy.id // empty' <<<"$BODY")"
  if [ -z "$EP_ID" ]; then
    err "service ${SVC_ID} has no escalation policy"; exit 1
  fi
  err "service ${SVC_ID} -> escalation policy ${EP_ID}"
  POLICY_IDS+=("$EP_ID")
fi

# resolve --user queries to ids via /users?query=
USER_IDS=()
for UQ in "${USER_QUERIES[@]+"${USER_QUERIES[@]}"}"; do
  RESP="$(pd_api -G "${BASE_URL}/users" --data-urlencode "query=${UQ}" \
    --data-urlencode "limit=2")"
  CODE="${RESP##*$'\n'}"; BODY="${RESP%$'\n'*}"
  pd_check "$BODY" "$CODE"
  N="$(jq -r '.users | length' <<<"$BODY")"
  if [ "$N" -eq 0 ]; then err "no user matched query '${UQ}'"; exit 1; fi
  if [ "$N" -ge 2 ]; then
    CANDS="$(jq -r '.users[:2][] | "  \(.id)  \(.summary)"' <<<"$BODY")"
    err "multiple users match '${UQ}'; pass the id directly. candidates:"
    err "$CANDS"
    exit 1
  fi
  UID_R="$(jq -r '.users[0].id' <<<"$BODY")"
  err "user '${UQ}' -> ${UID_R}"
  USER_IDS+=("$UID_R")
done

# assemble repeated array params as --data-urlencode pairs
PARAMS=()
for v in "${POLICY_IDS[@]+"${POLICY_IDS[@]}"}"; do
  PARAMS+=(--data-urlencode "escalation_policy_ids[]=${v}")
done
for v in "${SCHEDULE_IDS[@]+"${SCHEDULE_IDS[@]}"}"; do
  PARAMS+=(--data-urlencode "schedule_ids[]=${v}")
done
for v in "${USER_IDS[@]+"${USER_IDS[@]}"}"; do
  PARAMS+=(--data-urlencode "user_ids[]=${v}")
done
if [ -n "$AT" ]; then
  PARAMS+=(--data-urlencode "since=${AT}" --data-urlencode "until=${AT}")
fi
if [ "$EARLIEST" = "true" ]; then PARAMS+=(--data-urlencode "earliest=true"); fi

if [ "$FORMAT" = "tsv" ]; then printf 'level\tuser\tpolicy\tschedule\tuntil\n'; fi

OFFSET=0
FETCHED=0
REQS=0

while :; do
  RESP="$(pd_api -G "${BASE_URL}/oncalls" \
    "${PARAMS[@]+"${PARAMS[@]}"}" \
    --data-urlencode "limit=${PAGE_SIZE}" \
    --data-urlencode "offset=${OFFSET}")"
  CODE="${RESP##*$'\n'}"; PAGE="${RESP%$'\n'*}"
  pd_check "$PAGE" "$CODE"
  REQS=$(( REQS + 1 ))

  COUNT="$(jq -r '.oncalls // [] | length' <<<"$PAGE")"
  TAKE="$COUNT"
  if [ "$LIMIT" -gt 0 ]; then
    REMAINING=$(( LIMIT - FETCHED ))
    if [ "$COUNT" -gt "$REMAINING" ]; then TAKE="$REMAINING"; fi
  fi

  if [ "$TAKE" -gt 0 ]; then
    if [ "$FORMAT" = "tsv" ]; then
      jq -r --argjson take "$TAKE" '
        .oncalls[:$take][]
        | [(.escalation_level // ""), (.user.summary // ""),
           (.escalation_policy.summary // ""), (.schedule.summary // ""), (.end // "")]
        | @tsv' <<<"$PAGE"
    else
      jq -c --argjson take "$TAKE" '
        .oncalls[:$take][]
        | {level: .escalation_level, user: .user.summary,
           policy: .escalation_policy.summary, schedule: .schedule.summary,
           until: .end, start: .start}' <<<"$PAGE"
    fi
  fi
  FETCHED=$(( FETCHED + TAKE ))

  MORE="$(jq -r '.more // false' <<<"$PAGE")"
  if [ "$LIMIT" -gt 0 ] && [ "$FETCHED" -ge "$LIMIT" ]; then
    if [ "$MORE" = "true" ] || [ "$COUNT" -gt "$TAKE" ]; then
      err "output truncated at ${FETCHED} entries (raise --limit, or 0 for everything)"
    fi
    break
  fi
  if [ "$MORE" != "true" ] || [ "$COUNT" -eq 0 ]; then break; fi
  OFFSET=$(( OFFSET + COUNT ))
done

err "fetched ${FETCHED} on-call entries in ${REQS} request(s)"
