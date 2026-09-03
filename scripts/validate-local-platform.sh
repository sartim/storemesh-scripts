#!/usr/bin/env bash
set -euo pipefail

context="${STOREMESH_KUBE_CONTEXT:-kind-storemesh}"
kubectl_args=(--context "${context}")

echo "Validating StoreMesh platform on context: ${context}"

kubectl "${kubectl_args[@]}" get nodes >/dev/null
if kubectl "${kubectl_args[@]}" get nodes --no-headers | awk '$2 != "Ready" {print; failed=1} END {exit failed}'; then
  echo "Nodes: ready"
else
  echo "Nodes: not ready" >&2
  exit 1
fi

required_deployments=(
  "argocd/argocd-server"
  "argocd/argocd-repo-server"
  "istio-system/istiod"
  "istio-system/kiali"
  "storemesh-flagsmith/storemesh-flagsmith"
  "storemesh-flagsmith/storemesh-flagsmith-api"
  "storemesh-bff/storemesh-bff"
  "storemesh-frontend/storemesh-frontend"
  "storemesh-user-service/storemesh-user-service"
  "storemesh-product-service/storemesh-product-service"
  "storemesh-inventory-service/storemesh-inventory-service"
  "storemesh-order-service/storemesh-order-service"
  "storemesh-monitoring/prometheus-stack-kube-prom-operator"
  "storemesh-monitoring/prometheus-stack-grafana"
  "storemesh-monitoring/prometheus-stack-kube-state-metrics"
)

for item in "${required_deployments[@]}"; do
  namespace="${item%%/*}"
  deployment="${item#*/}"
  kubectl "${kubectl_args[@]}" -n "${namespace}" wait \
    --for=condition=Available "deployment/${deployment}" --timeout=180s
done

kubectl "${kubectl_args[@]}" -n elastic-system wait \
  --for=jsonpath='{.status.readyReplicas}'=1 statefulset/elastic-operator --timeout=180s

kubectl "${kubectl_args[@]}" -n storemesh-user-service wait \
  --for=condition=Available deployment/postgres deployment/redis --timeout=180s
kubectl "${kubectl_args[@]}" -n storemesh-monitoring wait \
  --for=condition=Ready pod/prometheus-prometheus-stack-kube-prom-prometheus-0 --timeout=180s
kubectl "${kubectl_args[@]}" -n storemesh-monitoring wait \
  --for=condition=Ready pod/alertmanager-prometheus-stack-kube-prom-alertmanager-0 --timeout=180s
kubectl "${kubectl_args[@]}" -n storemesh-logging wait \
  --for=jsonpath='{.status.phase}'=Ready elasticsearch/storemesh-logs --timeout=600s
kubectl "${kubectl_args[@]}" -n storemesh-logging wait \
  --for=condition=Available deployment/storemesh-logs-kb --timeout=600s

unready_pods="$(kubectl "${kubectl_args[@]}" get pods -A -o jsonpath='{range .items[?(@.status.phase=="Running")]}{range .status.conditions[?(@.type=="Ready")]}{.status}{" "}{end}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' | awk '$1 != "True" {print $2}')"
if [[ -n "${unready_pods}" ]]; then
  echo "Running pods without Ready=True:" >&2
  echo "${unready_pods}" >&2
  exit 1
fi

if kubectl "${kubectl_args[@]}" get events -A --field-selector=reason=OOMKilling --no-headers | grep -q .; then
  echo "OOMKilled events found:" >&2
  kubectl "${kubectl_args[@]}" get events -A --field-selector=reason=OOMKilling >&2
  exit 1
fi

echo "StoreMesh platform workloads are ready; Flagsmith, observability, and ECK logging are available."
