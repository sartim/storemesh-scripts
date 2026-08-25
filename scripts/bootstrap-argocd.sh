#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workspace_dir="${STOREMESH_PLATFORM_DIR:-$(cd "${script_dir}/../.." && pwd)}"
argocd_dir="${workspace_dir}/storemesh-argocd-repo"
argocd_manifest="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required but was not found on PATH." >&2
  exit 1
fi

if [ ! -f "${argocd_dir}/project.yaml" ] || \
  [ ! -f "${argocd_dir}/storemesh-user-service-application.yaml" ]; then
  echo "Argo CD definitions not found in ${argocd_dir}." >&2
  echo "Set STOREMESH_PLATFORM_DIR to the directory containing the StoreMesh repositories." >&2
  exit 1
fi

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
# Argo CD's generated CRDs can exceed kubectl's client-side apply annotation
# limit; server-side apply avoids storing the full manifest in metadata.
kubectl apply --server-side --force-conflicts \
  --namespace argocd \
  --filename "${argocd_manifest}"
kubectl wait \
  --namespace argocd \
  --for=condition=Available \
  deployment/argocd-server \
  --timeout=300s

kubectl apply --filename "${argocd_dir}/project.yaml"

if ! kubectl get secret \
  --namespace storemesh-user-service \
  storemesh-user-service-secrets >/dev/null 2>&1; then
  echo "Argo CD is ready, but deployment was not started." >&2
  echo "Create storemesh-user-service-secrets in namespace storemesh-user-service first." >&2
  exit 1
fi

kubectl apply --filename "${argocd_dir}/storemesh-user-service-application.yaml"

echo "Argo CD is installed and the StoreMesh user-service application was submitted."
