#!/usr/bin/env bash

set -euo pipefail

bff_url="${STOREMESH_BFF_URL:-http://localhost:8080}"
admin_token="${STOREMESH_ADMIN_TOKEN:-}"
customer_token="${STOREMESH_CUSTOMER_TOKEN:-}"
customer_email="${STOREMESH_CUSTOMER_EMAIL:-demo@storemesh.local}"
customer_password="${STOREMESH_CUSTOMER_PASSWORD:-StoreMesh-demo-2026!}"
admin_email="${STOREMESH_ADMIN_EMAIL:-admin@storemesh.local}"
admin_password="${STOREMESH_ADMIN_PASSWORD:-StoreMesh-admin-2026!}"

command -v jq >/dev/null || { echo "jq is required." >&2; exit 1; }

login() {
  local email="$1" password="$2"
  curl -fsS "${bff_url}/api/v1/auth/login" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg email "${email}" --arg password "${password}" '{email:$email,password:$password}')" \
    | jq -er '.accessToken // .access_token'
}

if [[ -z "${admin_token}" ]]; then
  admin_token="$(login "${admin_email}" "${admin_password}")"
fi
if [[ -z "${customer_token}" ]]; then
  customer_token="$(login "${customer_email}" "${customer_password}")"
fi

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
  'Ember Table Clock|SM-CLOK-017|6400|A quiet visual anchor for focused mornings.'
  'Vale Linen Apron|SM-APRN-018|5200|A sturdy layer for cooking, making, and hosting.'
  'Hearth Candle|SM-CNDL-019|3800|Warm cedar and amber for a softer room.'
  'North Ceramic Vase|SM-VASE-020|4600|A simple vessel for a single branch or bloom.'
  'Drift Reading Light|SM-LITE-021|7600|A portable pool of light for late chapters.'
  'Woven Storage Basket|SM-BASK-022|6900|Open storage with a calm, natural texture.'
  'Cedar Laptop Stand|SM-STND-023|8200|Raise your screen and make space to breathe.'
  'Rain Travel Umbrella|SM-UMBR-024|4100|Compact coverage for unexpected weather.'
  'Morrow Tea Infuser|SM-TEA-025|2200|A considered steep for leaves and quiet pauses.'
  'Pebble Bluetooth Tracker|SM-TRKR-026|5500|Keep everyday essentials close and findable.'
  'Aster Cotton Sheets|SM-SHTS-027|15900|Crisp, breathable comfort for better rest.'
  'Common Leather Wallet|SM-WLET-028|7200|A slim home for the cards you actually carry.'
  'Tide Picnic Blanket|SM-PICN-029|11200|A soft, durable base for outside hours.'
  'Mono USB-C Hub|SM-HUB-030|6800|One compact connection point for a busy setup.'
  'Juniper Hand Soap|SM-SOAP-031|2600|A fresh botanical wash for daily rituals.'
  'Loop Key Organizer|SM-KEYR-032|3300|A quieter, cleaner way to carry your keys.'
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
token_payload="$(printf '%s' "${customer_token}" | cut -d. -f2 | tr '_-' '/+' | awk '{ print $0 "===" }' | base64 --decode 2>/dev/null || printf '%s' "${customer_token}" | cut -d. -f2 | tr '_-' '/+' | awk '{ print $0 "===" }' | base64 -D 2>/dev/null || true)"
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
