#!/usr/bin/env bash
set -euo pipefail

applications=(
  storemesh-user-service/storemesh-user-service
  storemesh-product-service/storemesh-product-service
  storemesh-inventory-service/storemesh-inventory-service
  storemesh-order-service/storemesh-order-service
  storemesh-bff/storemesh-bff
)
for application in "${applications[@]}"; do
  namespace="${application%%/*}"
  deployment="${application#*/}"
  kubectl get namespace "$namespace" >/dev/null
  label="$(kubectl get namespace "$namespace" -o jsonpath='{.metadata.labels.istio-injection}')"
  [[ "$label" == "enabled" ]] || { echo "${namespace}: istio-injection is not enabled" >&2; exit 1; }
  selector="$(kubectl get deployment "$deployment" -n "$namespace" -o jsonpath='{.spec.selector.matchLabels.app\.kubernetes\.io/name}')"
  [[ -n "$selector" ]] || { echo "${namespace}/${deployment}: application selector is missing" >&2; exit 1; }
  all_ready=false
  for attempt in {1..60}; do
    pods="$(kubectl get pods -n "$namespace" -l "app.kubernetes.io/name=${selector}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
    [[ -n "$pods" ]] || { sleep 5; continue; }
    all_ready=true
    while IFS= read -r pod; do
      [[ -z "$pod" ]] && continue
      if ! containers="$(kubectl get pod "$pod" -n "$namespace" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)"; then
        all_ready=false
        break
      fi
      ready="$(kubectl get pod "$pod" -n "$namespace" -o jsonpath='{range .status.containerStatuses[*]}{.ready}{" "}{end}')"
      echo "${namespace}/${pod}: containers=${containers:-none} ready=${ready:-none}"
      if ! printf '%s\n' "$containers" | grep -qw istio-proxy || [[ "$ready" == *"false"* ]]; then
        all_ready=false
        break
      fi
    done <<< "$pods"
    [[ "$all_ready" == true ]] && break
    if [[ "$attempt" -eq 60 ]]; then
      echo "${namespace}: timed out waiting for current pods with ready Istio sidecars" >&2
      exit 1
    fi
    sleep 5
  done
  echo "${namespace}: enrolled and ready"
done
echo "Istio enrollment is healthy. Validate gRPC calls and telemetry before applying STRICT PeerAuthentication."
