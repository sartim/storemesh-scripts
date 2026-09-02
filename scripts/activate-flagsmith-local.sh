#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workspace_dir="${STOREMESH_PLATFORM_DIR:-$(cd "${script_dir}/../.." && pwd)}"
argocd_dir="${workspace_dir}/storemesh-argocd-repo"
flagsmith_key="${FLAGSMITH_SERVER_KEY:-}"
flagsmith_base_url="${FLAGSMITH_BASE_URL:-}"
bff_secret="storemesh-bff-flagsmith"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required but was not found on PATH." >&2
  exit 1
fi
if [ -z "${flagsmith_key}" ]; then
  echo "Set FLAGSMITH_SERVER_KEY to the Flagsmith server-side environment key." >&2
  exit 1
fi
if [ -z "${flagsmith_base_url}" ]; then
  echo "Set FLAGSMITH_BASE_URL to the in-cluster Flagsmith API URL." >&2
  echo "Example: http://flagsmith-api.storemesh-flagsmith.svc.cluster.local/" >&2
  exit 1
fi
if [ ! -f "${argocd_dir}/storemesh-flagsmith-application.yaml" ]; then
  echo "Flagsmith Argo CD manifest not found in ${argocd_dir}." >&2
  exit 1
fi

kubectl apply --filename "${argocd_dir}/storemesh-flagsmith-application.yaml"
kubectl create namespace storemesh-bff --dry-run=client -o yaml | kubectl apply --filename -
kubectl -n storemesh-bff create secret generic "${bff_secret}" \
  --from-literal=FLAGSMITH_API_KEY="${flagsmith_key}" \
  --dry-run=client -o yaml | kubectl apply --filename -

kubectl -n argocd patch application storemesh-bff --type merge --patch "$(cat <<PATCH
spec:
  source:
    helm:
      values: |
        replicaCount: 1
        config:
          flagsmithBaseURL: ${flagsmith_base_url}
        flagsmith:
          enabled: true
          existingSecret: ${bff_secret}
          apiKeyKey: FLAGSMITH_API_KEY
PATCH
)"

echo "Flagsmith is enabled for the local BFF."
echo "The server-side key was stored in ${bff_secret} and was not printed."
echo "Verify with: curl http://localhost:8080/api/v1/config"
