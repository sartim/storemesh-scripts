#!/usr/bin/env bash

set -euo pipefail

BFF_URL="${BFF_URL:-http://localhost:8080}"
FRONTEND_URL="${FRONTEND_URL:-http://localhost:3000}"
ACCESS_TOKEN="${ACCESS_TOKEN:-}"

check_url() {
  local name="$1"
  local url="$2"
  local body

  body="$(curl --fail-with-body --silent --show-error --location "$url")"
  if [[ -z "$body" ]]; then
    printf '%s returned an empty response: %s\n' "$name" "$url" >&2
    exit 1
  fi
  printf 'ok: %s (%s)\n' "$name" "$url"
}

check_url "BFF health" "$BFF_URL/healthz"
check_url "BFF product API" "$BFF_URL/api/v1/products"
check_url "Next.js frontend" "$FRONTEND_URL/"

if [[ -n "$ACCESS_TOKEN" ]]; then
  graphql_body='{"query":"{ products { id name priceMinor currency } }"}'
  curl --fail-with-body --silent --show-error \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H 'Content-Type: application/json' \
    --data "$graphql_body" \
    "$BFF_URL/api/v1/graphql" >/dev/null
  printf 'ok: authenticated BFF GraphQL products\n'
else
  printf 'skipped: authenticated GraphQL check (set ACCESS_TOKEN to enable)\n'
fi

printf 'Local application smoke checks passed.\n'
