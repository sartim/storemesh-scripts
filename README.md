# StoreMesh operational scripts

These scripts create a reproducible local StoreMesh platform from the sibling
configuration repositories. They are safe to rerun and never write runtime
credentials to Git.

Set `STOREMESH_PLATFORM_DIR` when the repositories are not checked out beside
one another. It should contain `storemesh-scripts`, `storemesh-kind-cluster`,
and `storemesh-argocd-repo`.

## Create the local cluster

Kind runs its nodes as Docker containers, so Docker Desktop or another local
Docker daemon must be running before this command. The script checks this and
reports a direct recovery message if the daemon is unavailable.

```sh
./scripts/create-kind-cluster.sh
```

## Run platform validation in GitHub Actions

The `Kind platform smoke` workflow creates a disposable Kind cluster on a
GitHub-hosted runner, bootstraps PostgreSQL/Redis and Argo CD, waits for the
StoreMesh workloads, validates Istio sidecars, checks the monitoring stack and
ECK-managed logging resources, then deletes the cluster. It runs weekly and can
be started manually from the Actions tab. Use this workflow for repeatable
platform validation so local Docker is only needed for interactive development.

For application feature work, run the changed frontend, BFF, or service
directly as a normal local development process and use the cluster only for
dependencies that are not convenient to run locally. Use the port-forward
helper for those dependencies, then reserve the GitHub Actions smoke workflow
for deployment, Istio, Argo CD, and observability validation. Do not recreate
the local cluster for ordinary application changes.

For infrastructure changes, prefer GitHub Actions as the first validation and
debugging environment. Use local Docker or Kubernetes only when reproducing a
container or cluster-specific issue requires interactive investigation.

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

The script installs Argo CD, waits for the Istio injector endpoint and webhook
registration to become ready, and then submits one local Application for each
current StoreMesh service, plus Istio, Prometheus, Tempo, Kiali, the ECK operator,
ECK-managed Elasticsearch/Kibana, and Fluent Bit. Staging Applications are not
submitted by this local bootstrap. It also waits for Argo repo-server to become
Available with a laptop-friendly health window before submitting dependent
applications.

## Enable local runtime feature flags

Flagsmith is optional and is not installed by the normal bootstrap. After
creating the local Flagsmith application and a server-side environment key in
its UI, activate it for the BFF without putting the key in Git:

```sh
export FLAGSMITH_SERVER_KEY='ser.replace-with-your-environment-key'
export FLAGSMITH_BASE_URL='http://flagsmith-api.storemesh-flagsmith.svc.cluster.local/'
./scripts/activate-flagsmith-local.sh
```

The helper applies the opt-in Argo Application, creates the BFF Secret, and
updates the BFF Application's Helm values. It never prints the key. Keep the
Flagsmith key server-side; web, Android, and iOS receive only the allow-listed
response from `GET /api/v1/config`.

The helper also creates the Flagsmith Django secret key before chart sync;
this avoids the chart's image-based secret-generation Job and keeps local
bootstrap independent of the `bitnamisecure/kubectl` image.

## Run the local UI and dashboards

## Validate the running local platform

Use the read-only validator after changes or restarts. It checks nodes, core
deployments, StoreMesh services, Flagsmith, Prometheus, Grafana, ECK-managed
Elasticsearch/Kibana, and OOMKilled events. It does not delete, recreate, or
modify the cluster:

```sh
./scripts/validate-local-platform.sh
```

Set `STOREMESH_KUBE_CONTEXT` when validating a different context.

After the local cluster and applications are ready, keep the forwarding helper
running in a terminal:

```sh
./scripts/port-forward-local.sh
```

Set `STOREMESH_KUBE_CONTEXT` when using a different Kubernetes context. The
helper keeps the frontend, BFF, Argo CD, Grafana, Prometheus, Alertmanager,
Tempo, Kiali, and Kibana forwards together and stops all child forwards when
interrupted. Observability forwards are optional while their operators are
starting; frontend, BFF, and Argo CD remain required.

## Seed the demo store

Import the curated demo catalog and 24 sample orders. The script logs in with
the local demo accounts by default; explicit tokens can still be supplied via
environment variables:

```sh
bash ./scripts/seed-demo-store.sh
```

The script skips duplicate product SKUs and uses idempotency keys for orders.
It writes through the BFF, so configured Product and Order persistence is used.

## Optional ngrok access

Use ngrok when a physical mobile device or a remote demo needs to reach the
local BFF. Start the normal local forwards first, then expose only the BFF:

```sh
ngrok http 8080
curl https://YOUR-NGROK-DOMAIN.ngrok-free.app/healthz
```

Configure the resulting HTTPS origin in the mobile client build settings. A
reserved ngrok domain is preferable for repeatable development. Add ngrok
authentication or rely on the application's login before sharing the URL,
and never tunnel PostgreSQL, Redis, gRPC, Prometheus, Grafana, Kibana, or Argo
CD directly.

## Istio gRPC validation

After the opt-in Istio applications synchronize, validate sidecar enrollment
before promoting mTLS from `PERMISSIVE` to `STRICT`:

```sh
./scripts/validate-istio-grpc.sh
```

The read-only check requires the enrolled namespaces to exist, each workload
to include an `istio-proxy` sidecar, and every container to be ready. It does
not change cluster state.

For repeatable telemetry and log volume after seeding, run the load harness. It
uses the local demo accounts by default and never prints bearer tokens:

```sh
bash ./scripts/load-demo-traffic.sh
```

The local demo credentials are:

```text
Customer: demo@storemesh.local / StoreMesh-demo-2026!
Admin:    admin@storemesh.local / StoreMesh-admin-2026!
```

These customer/admin credentials apply to the Frontend and BFF routes. Other
forwarded services use the following local access model:

| Service | Local credential or access |
| --- | --- |
| Frontend (`3000`) | Customer or admin demo account above |
| BFF (`8080`) | Customer or admin bearer token obtained from the login API |
| Argo CD (`8443`) | Username `admin`; retrieve the generated password with `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d; echo` |
| Grafana (`3001`) | Username `admin`; retrieve the generated password with `kubectl -n storemesh-monitoring get secret prometheus-stack-grafana -o jsonpath='{.data.admin-password}' \| base64 -d; echo` |
| Kiali (`20001`) | Anonymous access in the local Kind configuration |
| Kibana (`5601`) | Username `elastic`; retrieve its ECK-generated password using the command below |
| Prometheus (`9090`) | No authentication in the local setup |
| Alertmanager (`9093`) | No authentication in the local setup |
| Tempo (`3200`) | No authentication in the local setup |

Kibana uses the ECK-generated `elastic` user. Retrieve its password without
committing it:

```sh
kubectl --context kind-storemesh -n storemesh-logging get secret \
  storemesh-logs-es-elastic-user -o go-template='{{.data.elastic}}' | base64 -d; echo
```

Open Kibana at `https://localhost:5601` after the port-forward helper is
running; its local ECK certificate is self-signed.
