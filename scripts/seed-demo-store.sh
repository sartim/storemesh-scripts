#!/usr/bin/env bash

set -euo pipefail

bff_url="${STOREMESH_BFF_URL:-http://localhost:8080}"
admin_token="${STOREMESH_ADMIN_TOKEN:-}"
customer_token="${STOREMESH_CUSTOMER_TOKEN:-}"

if [[ -z "${admin_token}" || -z "${customer_token}" ]]; then
  echo "Set STOREMESH_ADMIN_TOKEN and STOREMESH_CUSTOMER_TOKEN first." >&2
  exit 1
fi
command -v jq >/dev/null || { echo "jq is required." >&2; exit 1; }

products=(
  'Halo Desk Lamp|SM-LAMP-001|8900|Warm ambient light for focused evenings.'
  'Cove Ceramic Mug|SM-MUG-002|2400|A quiet morning ritual, made tactile.'
  'Field Notes Set|SM-NOTE-003|1800|Three soft-cover notebooks for ideas in motion.'
  'Arc Wireless Charger|SM-CHRG-004|4200|A clean charging spot for your everyday carry.'
  'Dune Desk Tray|SM-TRAY-005|3600|Keep the small essentials beautifully together.'
  'Canvas Market Tote|SM-TOTE-006|2900|A durable carry-all for the daily route.'
  'Lumen Portable Speaker|SM-SPKR-007|12900|Room-filling sound in a compact silhouette.'
  'Still Water Bottle|SM-BOTT-008|3200|Double-wall steel, cool from first sip to last.'
  'Orbit Mechanical Keyboard|SM-KEYB-009|14900|A satisfying, considered typing experience.'
  'Cloud Wool Throw|SM-THRW-010|9800|A soft layer for slow Sunday afternoons.'
  'Moss Plant Pot|SM-POT-011|2700|A little green energy for the workspace.'
  'Ridge Headphones|SM-HEAD-012|18900|Focused listening with all-day comfort.'
  'Slate Cable Kit|SM-CABL-013|2100|The tidy answer to desk-side cable clutter.'
  'Sunday Coffee Beans|SM-COFF-014|1600|Bright, balanced beans for a better first cup.'
  'Studio Backpack|SM-BACK-015|11900|A calm, capable home for your daily essentials.'
  'Paperweight Stone|SM-STON-016|1400|A small grounded object for a busy desk.'
)

echo "Seeding product catalog..."
for entry in "${products[@]}"; do
  IFS='|' read -r name sku price description <<<"${entry}"
  curl -fsS -o /dev/null -w "${sku}: %{http_code}\n" \
    -X POST "${bff_url}/api/v1/admin/products" \
    -H "Authorization: Bearer ${admin_token}" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg sku "${sku}" --arg name "${name}" --arg description "${description}" --argjson price "${price}" '{sku:$sku,name:$name,description:$description,priceMinor:$price,currency:"USD"}')" \
    || true
done

products_json="$(curl -fsS "${bff_url}/api/v1/products?page_size=100" -H "Authorization: Bearer ${customer_token}")"
product_ids=()
while IFS= read -r product_id; do
  [ -n "${product_id}" ] && product_ids+=("${product_id}")
done <<EOF
$(jq -r '.products[]?.id // empty' <<<"${products_json}")
EOF
token_payload="$(printf '%s' "${customer_token}" | cut -d. -f2 | tr '_-' '/+' | awk '{ print $0 "===" }' | base64 -D 2>/dev/null || true)"
customer_id="$(jq -r '.sub // empty' <<<"${token_payload}")"

if [[ "${#product_ids[@]}" -eq 0 || -z "${customer_id}" ]]; then
  echo "Catalog or customer token is unavailable; no orders were created." >&2
  exit 1
fi

echo "Creating 24 demo orders for customer ${customer_id}..."
for i in $(seq 1 24); do
  product_id="${product_ids[$(( (i - 1) % ${#product_ids[@]} ))]}"
  quantity=$(( (i % 3) + 1 ))
  curl -fsS -o /dev/null -w "order-${i}: %{http_code}\n" \
    -X POST "${bff_url}/api/v1/orders" \
    -H "Authorization: Bearer ${customer_token}" \
    -H "Idempotency-Key: storemesh-demo-${i}" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg customer "${customer_id}" --arg product "${product_id}" --argjson quantity "${quantity}" '{customerId:$customer,lines:[{productId:$product,quantity:$quantity}]}')"
done

echo "Demo catalog and order history imported."
