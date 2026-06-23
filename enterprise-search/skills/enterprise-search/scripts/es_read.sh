#!/usr/bin/env bash
# Copyright 2026 Anthropic PBC
# SPDX-License-Identifier: Apache-2.0
# read full documents from the enterprise knowledge index with curl + jq: post
# /rest/api/v1/getdocuments with the given document ids and emit each document's full text.
# speaks the glean client api dialect — works against real glean or any glean-compatible
# backend; everything instance-specific comes from env vars.

set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  es_read.sh [options] DOC_ID [DOC_ID...]

  fetches the complete text of one or more documents by the document.id values returned by
  es_search.sh (the doc_id column).

options:
  --json       emit one json object per document (jsonl: {id, title, url, datasource, text})
               instead of plain text
  -h, --help   show this help

environment:
  GLEAN_BASE_URL   instance api root, e.g. https://company-be.glean.com (required)
  GLEAN_API_TOKEN  bearer token; injected by the runtime, so the placeholder default is fine

output:
  document text on stdout in reading order. with multiple ids and no --json, documents are
  separated by a "=== DOC_ID title ===" header line. per-document errors (not found / no
  access) go to stderr.

exit codes:
  0 all documents returned    1 any document errored, request failed, or bad arguments
EOF
}

err() { printf '%s\n' "$*" >&2; }

command -v curl >/dev/null || { err "curl is required"; exit 1; }
command -v jq >/dev/null || { err "jq is required"; exit 1; }

BASE_URL="${GLEAN_BASE_URL:-}"
TOKEN="${GLEAN_API_TOKEN:-placeholder}"
FORMAT=text
IDS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --json) FORMAT=json; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; IDS+=("$@"); break ;;
    -*) err "unknown option: $1 (see --help)"; exit 1 ;;
    *) IDS+=("$1"); shift ;;
  esac
done

[ "${#IDS[@]}" -gt 0 ] || { err "at least one DOC_ID is required (see --help)"; exit 1; }
[ -n "$BASE_URL" ] || { err "GLEAN_BASE_URL is not set"; exit 1; }
BASE_URL="${BASE_URL%/}"

# cap one request at 50 ids — glean's documented documentSpecs maximum
if [ "${#IDS[@]}" -gt 50 ]; then
  err "too many ids (${#IDS[@]}); maximum is 50 per call"
  exit 1
fi

specs=$(printf '%s\n' "${IDS[@]}" | jq -Rcn '[inputs | {id: .}]')
body=$(jq -cn --argjson specs "$specs" \
  '{documentSpecs: $specs, includeFields: ["DOCUMENT_CONTENT"]}')

resp=$(curl -sS --max-time 60 -w '\n%{http_code}' "${BASE_URL}/rest/api/v1/getdocuments" \
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

failures=0
multi=false
[ "${#IDS[@]}" -gt 1 ] && multi=true

for id in "${IDS[@]}"; do
  entry=$(printf '%s' "$payload" | jq -c --arg id "$id" \
    '.documents[$id] // {error: {errorCode: "MISSING", errorMessage: "no entry in response"}}')
  if printf '%s' "$entry" | jq -e '.error' >/dev/null; then
    err "$id: $(printf '%s' "$entry" | jq -r '.error.errorCode + " — " + .error.errorMessage')"
    failures=$((failures + 1))
    continue
  fi
  if [ "$FORMAT" = json ]; then
    printf '%s' "$entry" | jq -c '.document | {
      id, title, url,
      datasource: (.datasource // .metadata.datasource // ""),
      text: ((.content.fullTextList // []) | join("\n"))
    }'
  else
    if [ "$multi" = true ]; then
      title=$(printf '%s' "$entry" | jq -r '.document.title // ""')
      printf '=== %s %s ===\n' "$id" "$title"
    fi
    printf '%s' "$entry" | jq -r '(.document.content.fullTextList // []) | join("\n")'
  fi
done

[ "$failures" -eq 0 ] || exit 1
