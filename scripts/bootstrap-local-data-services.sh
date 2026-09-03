#!/usr/bin/env bash

set -euo pipefail

namespace="storemesh-user-service"
postgres_password="${STOREMESH_POSTGRES_PASSWORD:-storemesh-local-password}"
jwt_secret="${STOREMESH_JWT_SECRET:-$(head -c 48 /dev/urandom | base64 | tr -d '\n' | cut -c1-64)}"
customer_email="${STOREMESH_CUSTOMER_EMAIL:-demo@storemesh.local}"
customer_password="${STOREMESH_CUSTOMER_PASSWORD:-StoreMesh-demo-2026!}"
admin_email="${STOREMESH_ADMIN_EMAIL:-admin@storemesh.local}"
admin_password="${STOREMESH_ADMIN_PASSWORD:-StoreMesh-admin-2026!}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required but was not found on PATH." >&2
  exit 1
fi

kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply --validate=false -f -
kubectl label namespace "${namespace}" istio-injection=enabled --overwrite

kubectl -n "${namespace}" create secret generic storemesh-local-postgres \
  --from-literal=POSTGRES_USER=storemesh \
  --from-literal=POSTGRES_PASSWORD="${postgres_password}" \
  --from-literal=POSTGRES_DB=storemesh \
  --dry-run=client -o yaml | kubectl apply --validate=false -f -

kubectl apply --validate=false -f - <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: storemesh-user-service
spec:
  selector:
    app.kubernetes.io/name: postgres
  ports:
    - name: postgres
      port: 5432
      targetPort: postgres
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: storemesh-user-service
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: postgres
  template:
    metadata:
      labels:
        app.kubernetes.io/name: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          ports:
            - name: postgres
              containerPort: 5432
          envFrom:
            - secretRef:
                name: storemesh-local-postgres
          readinessProbe:
            exec:
              command: ["sh", "-c", "pg_isready -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\""]
            initialDelaySeconds: 5
            periodSeconds: 5
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: storemesh-user-service
spec:
  selector:
    app.kubernetes.io/name: redis
  ports:
    - name: redis
      port: 6379
      targetPort: redis
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: storemesh-user-service
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: redis
  template:
    metadata:
      labels:
        app.kubernetes.io/name: redis
    spec:
      containers:
        - name: redis
          image: redis:7-alpine
          ports:
            - name: redis
              containerPort: 6379
          readinessProbe:
            exec:
              command: ["redis-cli", "ping"]
            initialDelaySeconds: 5
            periodSeconds: 5
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              memory: 128Mi
YAML

kubectl -n "${namespace}" create secret generic storemesh-user-service-secrets \
  --from-literal=DATABASE_URL="postgres://storemesh:${postgres_password}@postgres.${namespace}.svc.cluster.local:5432/storemesh?sslmode=disable" \
  --from-literal=REDIS_URL="redis://redis.${namespace}.svc.cluster.local:6379/0" \
  --from-literal=JWT_SECRET="${jwt_secret}" \
  --from-literal=DEMO_CUSTOMER_EMAIL="${customer_email}" \
  --from-literal=DEMO_CUSTOMER_PASSWORD="${customer_password}" \
  --from-literal=DEMO_ADMIN_EMAIL="${admin_email}" \
  --from-literal=DEMO_ADMIN_PASSWORD="${admin_password}" \
  --dry-run=client -o yaml | kubectl apply --validate=false -f -

# Domain services use the same local PostgreSQL instance in the disposable
# Kind profile. Keep these secrets generated at bootstrap time and out of Git.
for service in storemesh-product-service storemesh-inventory-service storemesh-order-service; do
  kubectl create namespace "${service}" --dry-run=client -o yaml | kubectl apply --validate=false -f -
  kubectl label namespace "${service}" istio-injection=enabled --overwrite
done

kubectl -n storemesh-product-service create secret generic storemesh-product-service-secrets \
  --from-literal=DATABASE_URL="postgres://storemesh:${postgres_password}@postgres.${namespace}.svc.cluster.local:5432/storemesh?sslmode=disable" \
  --from-literal=JWT_SECRET="${jwt_secret}" \
  --dry-run=client -o yaml | kubectl apply --validate=false -f -

kubectl -n storemesh-inventory-service create secret generic storemesh-inventory-service-secrets \
  --from-literal=DATABASE_URL="postgres://storemesh:${postgres_password}@postgres.${namespace}.svc.cluster.local:5432/storemesh?sslmode=disable" \
  --dry-run=client -o yaml | kubectl apply --validate=false -f -

kubectl -n storemesh-order-service create secret generic storemesh-order-service-secrets \
  --from-literal=DATABASE_URL="postgres://storemesh:${postgres_password}@postgres.${namespace}.svc.cluster.local:5432/storemesh?sslmode=disable" \
  --from-literal=JWT_SECRET="${jwt_secret}" \
  --dry-run=client -o yaml | kubectl apply --validate=false -f -

kubectl -n "${namespace}" wait --for=condition=Available deployment/postgres --timeout=180s
kubectl -n "${namespace}" wait --for=condition=Available deployment/redis --timeout=180s

# The disposable cluster shares this PostgreSQL instance across the domain
# services. Apply their idempotent schemas here so functional smoke tests use
# the same persistent path as a deployed environment instead of falling back
# to an uninitialized database.
kubectl -n "${namespace}" exec -i deployment/postgres -- \
  env PGPASSWORD="${postgres_password}" psql -U storemesh -d storemesh \
  -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE IF NOT EXISTS products (
  id UUID PRIMARY KEY,
  sku TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  price_minor BIGINT NOT NULL CHECK (price_minor >= 0),
  currency TEXT NOT NULL,
  status SMALLINT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS products_status_idx ON products (status);

CREATE TABLE IF NOT EXISTS inventory_stock (
  product_id UUID PRIMARY KEY,
  on_hand BIGINT NOT NULL DEFAULT 0 CHECK (on_hand >= 0),
  reserved BIGINT NOT NULL DEFAULT 0 CHECK (reserved >= 0 AND reserved <= on_hand),
  updated_at TIMESTAMPTZ NOT NULL
);
CREATE TABLE IF NOT EXISTS inventory_reservations (
  reservation_id UUID PRIMARY KEY,
  product_id UUID NOT NULL REFERENCES inventory_stock(product_id),
  quantity BIGINT NOT NULL CHECK (quantity > 0),
  created_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS inventory_reservations_product_idx
  ON inventory_reservations (product_id);

CREATE TABLE IF NOT EXISTS orders (
  order_id UUID PRIMARY KEY,
  customer_id UUID NOT NULL,
  total_minor BIGINT NOT NULL CHECK (total_minor >= 0),
  currency TEXT NOT NULL,
  status SMALLINT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL
);
CREATE TABLE IF NOT EXISTS order_lines (
  order_id UUID NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
  line_number INTEGER NOT NULL,
  product_id UUID NOT NULL,
  quantity BIGINT NOT NULL CHECK (quantity > 0),
  unit_price_minor BIGINT NOT NULL CHECK (unit_price_minor >= 0),
  PRIMARY KEY (order_id, line_number)
);
CREATE INDEX IF NOT EXISTS orders_customer_idx ON orders (customer_id, created_at DESC);

CREATE TABLE IF NOT EXISTS carts (
  customer_id UUID PRIMARY KEY,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS cart_lines (
  customer_id UUID NOT NULL REFERENCES carts(customer_id) ON DELETE CASCADE,
  product_id UUID NOT NULL,
  quantity BIGINT NOT NULL CHECK (quantity > 0),
  PRIMARY KEY (customer_id, product_id)
);

CREATE TABLE IF NOT EXISTS event_outbox (
  event_id UUID PRIMARY KEY,
  aggregate_type TEXT NOT NULL,
  aggregate_id UUID NOT NULL,
  event_type TEXT NOT NULL,
  payload JSONB NOT NULL,
  occurred_at TIMESTAMPTZ NOT NULL,
  published_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS event_outbox_pending_idx
  ON event_outbox (occurred_at) WHERE published_at IS NULL;
SQL

kubectl -n "${namespace}" exec deployment/postgres -- \
  env PGPASSWORD="${postgres_password}" psql -U storemesh -d storemesh \
  -v ON_ERROR_STOP=1 -tAc "SELECT to_regclass('public.products')" | grep -qx products

echo "Local PostgreSQL, Redis, and user-service credentials are ready."
