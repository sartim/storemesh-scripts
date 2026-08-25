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

## Install Argo CD and submit the application

```sh
./scripts/bootstrap-argocd.sh
```
