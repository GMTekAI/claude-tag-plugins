#!/usr/bin/env bash
# Copyright 2026 Anthropic PBC
# SPDX-License-Identifier: Apache-2.0
# list and filter linear issues with curl + jq over the graphql endpoint: build an IssueFilter
# from flags (with a viewer pre-query for "--assignee me"), page through pageInfo.endCursor,
# surface the .errors envelope (graphql returns 200 on failures), and emit tsv or jsonl. generic
# to any linear workspace — everything instance-specific comes from env vars or flags.

set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  linear_issues.sh [options]

options:
  --team KEY         filter to one team by key, e.g. ENG
  --state NAME       workflow state name, e.g. "In Progress"
  --state-type TYPE  workflow state type: backlog unstarted started completed canceled triage
  --assignee EMAIL   assignee email; pass "me" to mean the configured identity
  --label NAME       label name (matches issues with at least that label)
  --query TEXT       case-insensitive substring match over title and description
  --limit N          stop after N issues total (default 50; 0 = fetch everything)
  --page-size N      issues per page, max 100 (default 50)
  --json             emit one json object per issue (jsonl) instead of tsv
  -h, --help         show this help

environment:
  LINEAR_API_KEY    api key; injected by the runtime, so the placeholder default is fine
  LINEAR_BASE_URL   api root override (default https://api.linear.app)

output:
  issues on stdout — tsv with header (identifier, title, state, assignee, updatedAt, url) by
  default, jsonl with --json. row counts and any truncation warning go to stderr.

exit codes:
  0 success    1 request failed, graphql error, or bad arguments
EOF
}

err() { printf '%s\n' "$*" >&2; }

command -v curl >/dev/null || { err "curl is required"; exit 1; }
command -v jq >/dev/null || { err "jq is required"; exit 1; }

BASE_URL="${LINEAR_BASE_URL:-https://api.linear.app}"
API_KEY="${LINEAR_API_KEY:-placeholder}"
TEAM=""
STATE_NAME=""
STATE_TYPE=""
ASSIGNEE=""
LABEL=""
QUERY=""
LIMIT=50
PAGE_SIZE=50
FORMAT=tsv

# require_int FLAG VALUE — flags that take a count must get a non-negative integer
require_int() {
  case "$2" in
    ''|*[!0-9]*) err "$1 needs a non-negative integer, got '${2:-nothing}'"; exit 1 ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --team)
      [ -n "${2:-}" ] || { err "--team needs a team key"; exit 1; }
      TEAM="$2"; shift 2 ;;
    --state)
      [ -n "${2:-}" ] || { err "--state needs a state name"; exit 1; }
      STATE_NAME="$2"; shift 2 ;;
    --state-type)
      case "${2:-}" in
        backlog|unstarted|started|completed|canceled|triage) STATE_TYPE="$2" ;;
        *) err "--state-type must be one of: backlog unstarted started completed canceled triage"
           exit 1 ;;
      esac
      shift 2 ;;
    --assignee)
      [ -n "${2:-}" ] || { err "--assignee needs an email or 'me'"; exit 1; }
      ASSIGNEE="$2"; shift 2 ;;
    --label)
      [ -n "${2:-}" ] || { err "--label needs a label name"; exit 1; }
      LABEL="$2"; shift 2 ;;
    --query)
      [ -n "${2:-}" ] || { err "--query needs text"; exit 1; }
      QUERY="$2"; shift 2 ;;
    --limit) require_int --limit "${2:-}"; LIMIT="$2"; shift 2 ;;
    --page-size)
      require_int --page-size "${2:-}"
      if [ "$2" -lt 1 ] || [ "$2" -gt 100 ]; then err "--page-size must be 1..100"; exit 1; fi
      PAGE_SIZE="$2"; shift 2 ;;
    --json) FORMAT=json; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) err "unknown option: $1 (see --help)"; exit 1 ;;
    *) err "unexpected argument: $1 (see --help)"; exit 1 ;;
  esac
done

linear_api() {
  curl -sS --max-time 60 \
    -H "Authorization: ${API_KEY}" \
    -H "Content-Type: application/json" \
    -X POST "${BASE_URL}/graphql" -d "$1"
}

# graphql sends most failures as http 200 with .errors[] — check that first, then for missing data
linear_check_error() {
  if ! jq -e . >/dev/null 2>&1 <<<"$1"; then
    err "non-json response from the api:"
    printf '%s\n' "$1" | head -c 2000 >&2
    exit 1
  fi
  if [ "$(jq -r 'has("errors") and (.errors | length > 0)' <<<"$1")" = "true" ]; then
    jq -r '.errors[0] | "linear error" +
      (if .extensions.code then " " + .extensions.code else "" end) + ": " +
      (.message // "unknown error")' <<<"$1" >&2
    exit 1
  fi
  if [ "$(jq -r 'has("data") and .data != null' <<<"$1")" != "true" ]; then
    err "linear error: response has no data field"
    exit 1
  fi
}

# build the IssueFilter from set flags — keys for absent flags are omitted entirely
BASE='{}'
if [ -n "$TEAM" ]; then
  BASE="$(jq -c --arg v "$TEAM" '. + {team: {key: {eq: $v}}}' <<<"$BASE")"
fi
if [ -n "$STATE_NAME" ]; then
  BASE="$(jq -c --arg v "$STATE_NAME" '. * {state: {name: {eq: $v}}}' <<<"$BASE")"
fi
if [ -n "$STATE_TYPE" ]; then
  BASE="$(jq -c --arg v "$STATE_TYPE" '. * {state: {type: {eq: $v}}}' <<<"$BASE")"
fi
if [ -n "$LABEL" ]; then
  BASE="$(jq -c --arg v "$LABEL" '. + {labels: {some: {name: {eq: $v}}}}' <<<"$BASE")"
fi
if [ -n "$ASSIGNEE" ]; then
  if [ "$ASSIGNEE" = "me" ]; then
    # IssueFilter has no "me" shorthand — resolve viewer.id with a tiny pre-query
    VRESP="$(linear_api "$(jq -cn '{query: "{ viewer { id } }"}')")"
    linear_check_error "$VRESP"
    VID="$(jq -r '.data.viewer.id // empty' <<<"$VRESP")"
    [ -n "$VID" ] || { err "could not resolve viewer id for --assignee me"; exit 1; }
    BASE="$(jq -c --arg v "$VID" '. + {assignee: {id: {eq: $v}}}' <<<"$BASE")"
  else
    BASE="$(jq -c --arg v "$ASSIGNEE" '. + {assignee: {email: {eq: $v}}}' <<<"$BASE")"
  fi
fi

if [ -n "$QUERY" ]; then
  ORB="$(jq -cn --arg q "$QUERY" \
    '{or: [{title: {containsIgnoreCase: $q}}, {description: {containsIgnoreCase: $q}}]}')"
  if [ "$BASE" = '{}' ]; then
    FILTER="$ORB"
  else
    FILTER="$(jq -cn --argjson b "$BASE" --argjson o "$ORB" '{and: [$b, $o]}')"
  fi
else
  FILTER="$BASE"
fi

read -r -d '' GQL <<'EOF' || true
query($filter: IssueFilter, $cursor: String, $first: Int) {
  issues(first: $first, after: $cursor, orderBy: updatedAt, filter: $filter) {
    pageInfo { hasNextPage endCursor }
    nodes { identifier title state { name } assignee { name } updatedAt url }
  }
}
EOF

if [ "$FORMAT" = "tsv" ]; then
  printf 'identifier\ttitle\tstate\tassignee\tupdatedAt\turl\n'
fi

CURSOR=""
FETCHED=0
TRUNCATED=false

while :; do
  BODY="$(jq -cn --arg q "$GQL" --argjson f "$FILTER" --argjson n "$PAGE_SIZE" --arg c "$CURSOR" \
    '{query: $q, variables: {filter: $f, first: $n,
      cursor: (if $c == "" then null else $c end)}}')"
  PAGE="$(linear_api "$BODY")"
  linear_check_error "$PAGE"

  COUNT="$(jq -r '.data.issues.nodes | length' <<<"$PAGE")"
  TAKE="$COUNT"
  if [ "$LIMIT" -gt 0 ]; then
    REMAINING=$(( LIMIT - FETCHED ))
    if [ "$COUNT" -gt "$REMAINING" ]; then TAKE="$REMAINING"; fi
  fi

  if [ "$TAKE" -gt 0 ]; then
    if [ "$FORMAT" = "tsv" ]; then
      jq -r --argjson take "$TAKE" '.data.issues.nodes[:$take][]
        | [.identifier, .title, (.state.name // ""), (.assignee.name // ""),
           .updatedAt, .url] | @tsv' <<<"$PAGE"
    else
      jq -c --argjson take "$TAKE" '.data.issues.nodes[:$take][]' <<<"$PAGE"
    fi
  fi
  FETCHED=$(( FETCHED + TAKE ))

  MORE="$(jq -r '.data.issues.pageInfo.hasNextPage // false' <<<"$PAGE")"
  CURSOR="$(jq -r '.data.issues.pageInfo.endCursor // empty' <<<"$PAGE")"
  if [ "$LIMIT" -gt 0 ] && [ "$FETCHED" -ge "$LIMIT" ]; then
    if [ "$MORE" = "true" ] || [ "$COUNT" -gt "$TAKE" ]; then TRUNCATED=true; fi
    break
  fi
  if [ "$MORE" != "true" ] || [ -z "$CURSOR" ]; then break; fi
done

err "fetched ${FETCHED} issue(s)"
if [ "$TRUNCATED" = "true" ]; then
  err "output truncated at ${FETCHED} issues (raise --limit, or 0 for everything)"
fi
