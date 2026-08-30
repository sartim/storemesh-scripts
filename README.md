# StoreMesh operational scripts

These scripts create a reproducible local StoreMesh platform from the sibling
configuration repositories. They are safe to rerun and never write runtime
credentials to Git.

Set `STOREMESH_PLATFORM_DIR` when the repositories are not checked out beside
one another. It should contain `storemesh-scripts`, `storemesh-kind-cluster`,
and `storemesh-argocd-repo`.

## Create the local cluster

```sh
./scripts/create-kind-cluster.sh
```

## Supply runtime credentials

Create the namespace and secret before submitting the Argo CD application:

```sh
kubectl create namespace storemesh-user-service
kubectl create secret generic storemesh-user-service-secrets \
  --namespace storemesh-user-service \
  --from-literal=DATABASE_URL='postgres://...' \
  --from-literal=REDIS_URL='redis://...' \
  --from-literal=JWT_SECRET='replace-with-a-strong-secret'
```

Use a secret manager or External Secrets in a shared environment instead of
putting credential values in shell history.

## Install Argo CD and submit the local applications

```sh
./scripts/bootstrap-argocd.sh
```

The script installs Argo CD and submits one local Application for each current
StoreMesh service, plus Istio, Prometheus, and Tempo. Staging Applications are
not submitted by this local bootstrap.

## Run the local UI and dashboards

After the local cluster and applications are ready, keep the forwarding helper
running in a terminal:

```sh
./scripts/port-forward-local.sh
```

Set `STOREMESH_KUBE_CONTEXT` when using a different Kubernetes context. The
helper keeps the frontend, BFF, Argo CD, Grafana, Prometheus, Alertmanager, and
Tempo forwards together and stops all child forwards when interrupted.

## Seed the demo store

After obtaining a customer token and an admin token, import the curated demo
catalog and 24 sample orders:

```sh
STOREMESH_CUSTOMER_TOKEN=... \
STOREMESH_ADMIN_TOKEN=... \
bash ./scripts/seed-demo-store.sh
```

The script skips duplicate product SKUs and uses idempotency keys for orders.
It writes through the BFF, so configured Product and Order persistence is used.
