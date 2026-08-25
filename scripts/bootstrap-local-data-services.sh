#!/usr/bin/env bash

set -euo pipefail

namespace="storemesh-user-service"
postgres_password="${STOREMESH_POSTGRES_PASSWORD:-storemesh-local-password}"
jwt_secret="${STOREMESH_JWT_SECRET:-$(head -c 48 /dev/urandom | base64 | tr -d '\n' | cut -c1-64)}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required but was not found on PATH." >&2
  exit 1
fi

kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "${namespace}" create secret generic storemesh-local-postgres \
  --from-literal=POSTGRES_USER=storemesh \
  --from-literal=POSTGRES_PASSWORD="${postgres_password}" \
  --from-literal=POSTGRES_DB=storemesh \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<'YAML'
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
YAML

kubectl -n "${namespace}" create secret generic storemesh-user-service-secrets \
  --from-literal=DATABASE_URL="postgres://storemesh:${postgres_password}@postgres.${namespace}.svc.cluster.local:5432/storemesh?sslmode=disable" \
  --from-literal=REDIS_URL="redis://redis.${namespace}.svc.cluster.local:6379/0" \
  --from-literal=JWT_SECRET="${jwt_secret}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "${namespace}" wait --for=condition=Available deployment/postgres --timeout=180s
kubectl -n "${namespace}" wait --for=condition=Available deployment/redis --timeout=180s

echo "Local PostgreSQL, Redis, and user-service credentials are ready."
