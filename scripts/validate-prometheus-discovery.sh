#!/usr/bin/env bash
set -euo pipefail

monitoring_namespace="${STOREMESH_MONITORING_NAMESPACE:-storemesh-monitoring}"
prometheus_service="${STOREMESH_PROMETHEUS_SERVICE:-prometheus-stack-kube-prom-prometheus}"
port="${STOREMESH_PROMETHEUS_PORT:-19090}"
forward_log="$(mktemp -t storemesh-prometheus-forward.XXXXXX)"
forward_pid=""

cleanup() {
  if [[ -n "${forward_pid}" ]]; then
    kill "${forward_pid}" 2>/dev/null || true
    wait "${forward_pid}" 2>/dev/null || true
  fi
  rm -f "${forward_log}"
}
trap cleanup EXIT

services=(user-service product-service inventory-service order-service)
for service in "${services[@]}"; do
  namespace="storemesh-${service}"
  if ! kubectl -n "${namespace}" get servicemonitor "storemesh-${service}" >/dev/null 2>&1; then
    echo "Missing ServiceMonitor storemesh-${service} in ${namespace}." >&2
    exit 1
  fi
done

kubectl -n "${monitoring_namespace}" port-forward "svc/${prometheus_service}" "${port}:9090" >"${forward_log}" 2>&1 &
forward_pid=$!
for attempt in {1..30}; do
  if curl --fail --silent "http://127.0.0.1:${port}/-/ready" >/dev/null; then
    break
  fi
  if [[ "${attempt}" -eq 30 ]]; then
    cat "${forward_log}" >&2
    exit 1
  fi
  sleep 2
done

targets="$(curl --fail --silent "http://127.0.0.1:${port}/api/v1/targets?state=active")"
active_count="$(jq '[.data.activeTargets[] | select(.health == "up") | select((.labels.namespace // "") | startswith("storemesh-"))] | length' <<<"${targets}")"
missing_namespaces=""
for service in "${services[@]}"; do
  namespace="storemesh-${service}"
  if ! jq -e --arg namespace "${namespace}" \
    '[.data.activeTargets[] | select(.health == "up" and .labels.namespace == $namespace)] | length > 0' \
    <<<"${targets}" >/dev/null; then
    missing_namespaces+="${namespace}\n"
  fi
done
if [[ "${active_count}" -lt "${#services[@]}" ]]; then
  echo "Expected one healthy StoreMesh target per domain service; found ${active_count}." >&2
  echo "Missing healthy namespaces:" >&2
  printf '%b' "${missing_namespaces}" >&2
  jq '.data.activeTargets | map({job: .labels.job, namespace: .labels.namespace, health: .health, lastError: .lastError})' <<<"${targets}" >&2
  exit 1
fi

echo "Prometheus discovery is healthy: ${active_count} active StoreMesh targets reported."
