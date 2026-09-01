#!/usr/bin/env bash

set -eo pipefail

context="${STOREMESH_KUBE_CONTEXT:-kind-storemesh}"
server_args=()
if [[ -n "${STOREMESH_KUBE_SERVER:-}" ]]; then
  server_args=(--server "${STOREMESH_KUBE_SERVER}")
fi
log_dir="${TMPDIR:-/tmp}/storemesh-port-forwards"
pids=()
required_pids=()

cleanup() {
  trap - EXIT INT TERM
  if ((${#pids[@]} == 0)); then
    return
  fi
  for pid in "${pids[@]}"; do
    kill "${pid}" 2>/dev/null || true
  done
  for pid in "${pids[@]}"; do
    wait "${pid}" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required but was not found on PATH." >&2
  exit 1
fi

kubectl --context "${context}" "${server_args[@]}" cluster-info --request-timeout=30s >/dev/null
mkdir -p "${log_dir}"

forward() {
  local name="$1"
  local namespace="$2"
  local service="$3"
  local ports="$4"
  local required="${5:-required}"

  if ! kubectl --context "${context}" "${server_args[@]}" get service "${service}" --namespace "${namespace}" --request-timeout=30s >/dev/null; then
    if [[ "${required}" == "required" ]]; then
      return 1
    fi
    echo "Optional forward ${name} could not be started; see ${log_dir}/${name}.log." >&2
    return 0
  fi
  kubectl --context "${context}" port-forward \
    "${server_args[@]}" \
    --namespace "${namespace}" \
    "service/${service}" "${ports}" \
    >"${log_dir}/${name}.log" 2>&1 &
  pids+=("$!")
  if [[ "${required}" == "required" ]]; then
    required_pids+=("$!")
  fi
}

forward frontend storemesh-frontend storemesh-frontend 3000:3000
forward bff storemesh-bff storemesh-bff 8080:8080
forward argocd argocd argocd-server 8443:443
forward grafana storemesh-monitoring prometheus-stack-grafana 3001:80 optional
forward prometheus storemesh-monitoring prometheus-stack-kube-prom-prometheus 9090:9090 optional
forward alertmanager storemesh-monitoring prometheus-stack-kube-prom-alertmanager 9093:9093 optional
forward tempo storemesh-monitoring tempo 3200:3200 optional

cat <<EOF
StoreMesh local forwards are running with context: ${context}

Frontend:    http://localhost:3000
BFF health:  http://localhost:8080/healthz
Argo CD:     https://localhost:8443
Grafana:     http://localhost:3001
Prometheus:  http://localhost:9090
Alertmanager:http://localhost:9093
Tempo:       http://localhost:3200

Logs: ${log_dir}
Press Ctrl-C to stop all forwards.
EOF

while :; do
  for pid in "${required_pids[@]}"; do
    if ! kill -0 "${pid}" 2>/dev/null; then
      echo "A port-forward stopped unexpectedly. Check logs in ${log_dir}." >&2
      exit 1
    fi
  done
  sleep 2
done
