#!/usr/bin/env bash

set -euo pipefail

BFF_URL="${BFF_URL:-http://localhost:8080}"
FRONTEND_URL="${FRONTEND_URL:-http://localhost:3000}"
USER_SERVICE_URL="${USER_SERVICE_URL:-http://localhost:8090}"
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
check_url "User Service health" "$USER_SERVICE_URL/healthz"
check_url "BFF product API" "$BFF_URL/api/v1/products"
check_url "Next.js frontend" "$FRONTEND_URL/"

if [[ -n "$ACCESS_TOKEN" ]]; then
  graphql_body='{"query":"{ products { products { id name priceMinor currency } } }"}'
  products_response="$(curl --fail-with-body --silent --show-error \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H 'Content-Type: application/json' \
    --data "$graphql_body" \
    "$BFF_URL/api/v1/graphql")"
  if ! jq -e '((.errors // []) | length) == 0 and (.data.products.products | length) > 0' >/dev/null <<<"$products_response"; then
    printf 'authenticated BFF GraphQL products response was invalid\n' >&2
    exit 1
  fi
  printf 'ok: authenticated BFF GraphQL products\n'

  if [[ "${RUN_COMMERCE_FLOW:-0}" == "1" ]]; then
    product_id="$(jq -r '.data.products.products[0].id' <<<"$products_response")"
    commerce_query() {
      local query="$1"
      local response
      response="$(curl --fail-with-body --silent --show-error \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H 'Content-Type: application/json' \
        --data "$(jq -cn --arg query "$query" '{query: $query}')" \
        "$BFF_URL/api/v1/graphql")"
      if ! jq -e '((.errors // []) | length) == 0' >/dev/null <<<"$response"; then
        printf 'authenticated BFF GraphQL commerce response was invalid\n' >&2
        exit 1
      fi
      printf '%s' "$response"
    }

    commerce_query '{ cart { lines { productId quantity } } }' >/dev/null
    commerce_query "mutation { updateCart(lines: [{ productId: \"$product_id\", quantity: 1 }]) { lines { productId quantity } } }" \
      | jq -e --arg product_id "$product_id" '.data.updateCart.lines | any(.[]; .productId == $product_id and .quantity == 1)' >/dev/null
    idempotency_key="storemesh-local-$(date +%s)-$$"
    commerce_query "mutation { createOrder(lines: [{ productId: \"$product_id\", quantity: 1 }], idempotencyKey: \"$idempotency_key\") { id status } }" \
      | jq -e '.data.createOrder.id != null and .data.createOrder.id != ""' >/dev/null
    commerce_query 'mutation { clearCart { lines { productId quantity } } }' \
      | jq -e '.data.clearCart.lines | length == 0' >/dev/null
    printf 'ok: authenticated BFF commerce flow (cart, idempotent order, clear cart)\n'
  else
    printf 'skipped: commerce flow (set RUN_COMMERCE_FLOW=1 to enable)\n'
  fi
else
  printf 'skipped: authenticated GraphQL check (set ACCESS_TOKEN to enable)\n'
fi

printf 'Local application smoke checks passed.\n'
