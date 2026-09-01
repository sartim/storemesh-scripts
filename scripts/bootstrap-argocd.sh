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

# ECK installs many CRDs and namespaced operator resources. Create its target
# namespace before the CRD-heavy sync so Argo does not race CreateNamespace with
# the first batch of operator resources on a small local Kind cluster.
kubectl create namespace elastic-system --dry-run=client -o yaml | kubectl apply -f -

if ! kubectl get secret \
  --namespace storemesh-user-service \
  storemesh-user-service-secrets >/dev/null 2>&1; then
  echo "Argo CD is ready, but deployment was not started." >&2
  echo "Create storemesh-user-service-secrets in namespace storemesh-user-service first." >&2
  exit 1
fi

application_manifests=(
  istio-base-application.yaml
  istiod-application.yaml
  istio-ingressgateway-application.yaml
  kiali-application.yaml
  eck-operator-application.yaml
  eck-logging-application.yaml
  fluent-bit-application.yaml
  prometheus-stack-application.yaml
  tempo-application.yaml
  storemesh-user-service-application.yaml
  storemesh-product-service-application.yaml
  storemesh-inventory-service-application.yaml
  storemesh-order-service-application.yaml
  storemesh-bff-application.yaml
  storemesh-frontend-application.yaml
)

for manifest in "${application_manifests[@]}"; do
  kubectl apply --filename "${argocd_dir}/${manifest}"
done

echo "Argo CD is installed and the local StoreMesh applications were submitted."
