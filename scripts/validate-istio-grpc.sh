#!/usr/bin/env bash
set -euo pipefail

namespaces=(storemesh-user-service storemesh-product-service storemesh-inventory-service storemesh-order-service storemesh-bff)
for namespace in "${namespaces[@]}"; do
  kubectl get namespace "$namespace" >/dev/null
  label="$(kubectl get namespace "$namespace" -o jsonpath='{.metadata.labels.istio-injection}')"
  [[ "$label" == "enabled" ]] || { echo "${namespace}: istio-injection is not enabled" >&2; exit 1; }
  pods="$(kubectl get pods -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
  [[ -n "$pods" ]] || { echo "${namespace}: no pods found" >&2; exit 1; }
  while IFS= read -r pod; do
    [[ -z "$pod" ]] && continue
    containers="$(kubectl get pod "$pod" -n "$namespace" -o jsonpath='{.spec.containers[*].name}')"
    [[ " $containers " == *" istio-proxy "* ]] || { echo "${namespace}/${pod}: istio-proxy is missing" >&2; exit 1; }
    ready="$(kubectl get pod "$pod" -n "$namespace" -o jsonpath='{range .status.containerStatuses[*]}{.ready}{" "}{end}')"
    [[ "$ready" != *"false"* ]] || { echo "${namespace}/${pod}: a container is not ready" >&2; exit 1; }
  done <<< "$pods"
  echo "${namespace}: enrolled and ready"
done
echo "Istio enrollment is healthy. Validate gRPC calls and telemetry before applying STRICT PeerAuthentication."
