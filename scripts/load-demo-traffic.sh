#!/usr/bin/env bash

set -euo pipefail

bff_url="${STOREMESH_BFF_URL:-http://localhost:8080}"
customer_email="${STOREMESH_CUSTOMER_EMAIL:-demo@storemesh.local}"
customer_password="${STOREMESH_CUSTOMER_PASSWORD:-StoreMesh-demo-2026!}"
admin_email="${STOREMESH_ADMIN_EMAIL:-admin@storemesh.local}"
admin_password="${STOREMESH_ADMIN_PASSWORD:-StoreMesh-admin-2026!}"
requests="${STOREMESH_TRAFFIC_REQUESTS:-120}"

command -v curl >/dev/null || { echo "curl is required." >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required." >&2; exit 1; }

login() {
  local email="$1" password="$2"
  curl -fsS "${bff_url}/api/v1/auth/login" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg email "${email}" --arg password "${password}" '{email:$email,password:$password}')" \
    | jq -er '.accessToken // .access_token'
}

health="$(curl -fsS "${bff_url}/healthz")"
echo "BFF health: ${health}"
customer_token="$(login "${customer_email}" "${customer_password}")"
admin_token="$(login "${admin_email}" "${admin_password}")"

customer_auth=( -H "Authorization: Bearer ${customer_token}" )
admin_auth=( -H "Authorization: Bearer ${admin_token}" )
ok=0
failed=0

request() {
  local method="$1" url="$2"; shift 2
  local status
  status="$(curl -sS -o /dev/null -w '%{http_code}' -X "${method}" "${bff_url}${url}" "$@" || true)"
  if [[ "${status}" =~ ^2 ]]; then ((ok+=1)); else ((failed+=1)); fi
}

echo "Generating ${requests} read requests plus representative admin traffic..."
for i in $(seq 1 "${requests}"); do
  request GET "/api/v1/products?page_size=100" "${customer_auth[@]}"
  request GET "/api/v1/orders?page_size=100" "${customer_auth[@]}"
  if (( i % 4 == 0 )); then
    request GET "/api/v1/admin/products" "${admin_auth[@]}"
    request GET "/api/v1/admin/users?per_page=100" "${admin_auth[@]}"
  fi
done

echo "Traffic complete: ${ok} successful, ${failed} failed requests."
if (( failed > 0 )); then exit 1; fi
