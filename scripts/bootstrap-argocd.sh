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

platform_manifests=(
  istio-base-application.yaml
  istiod-application.yaml
  istio-ingressgateway-application.yaml
  istio-mesh-policy-application.yaml
)

for manifest in "${platform_manifests[@]}"; do
  kubectl apply --filename "${argocd_dir}/${manifest}"
done

# Domain workloads must not be created until the Istio injector is serving;
# otherwise a namespace label can exist while the first pods miss sidecars.
for attempt in {1..120}; do
  if kubectl get namespace istio-system >/dev/null 2>&1 && kubectl -n istio-system get deployment istiod >/dev/null 2>&1; then
    break
  fi
  if [ "${attempt}" -eq 120 ]; then
    echo "Timed out waiting for the Istio control-plane deployment." >&2
    exit 1
  fi
  sleep 5
done
kubectl -n istio-system wait --for=condition=Available deployment/istiod --timeout=600s
for attempt in {1..60}; do
  if kubectl -n istio-system get endpoints istiod -o jsonpath='{.subsets[*].addresses[*].ip}' | grep -q .; then
    break
  fi
  if [ "${attempt}" -eq 60 ]; then
    echo "Timed out waiting for an Istiod service endpoint." >&2
    exit 1
  fi
  sleep 5
done
for attempt in {1..60}; do
  if kubectl get mutatingwebhookconfiguration -o name | grep -q 'istio-sidecar-injector'; then
    break
  fi
  if [ "${attempt}" -eq 60 ]; then
    echo "Timed out waiting for the Istio sidecar injector webhook." >&2
    exit 1
  fi
  sleep 5
done

# Create and label workload namespaces before submitting their Argo
# Applications. Relying only on CreateNamespace plus managedNamespaceMetadata
# leaves a small but real window where the first Deployment can create pods
# before the Istio namespace selector is present.
workload_namespaces=(
  storemesh-user-service
  storemesh-product-service
  storemesh-inventory-service
  storemesh-order-service
  storemesh-bff
  storemesh-frontend
)
for namespace in "${workload_namespaces[@]}"; do
  kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace "${namespace}" istio-injection=enabled --overwrite
done

# ECK logging resources must not be submitted until the operator and its CRDs
# are serving. Otherwise Argo can apply Elasticsearch but lose the Kibana
# resource during the operator/webhook startup race.
kubectl create namespace storemesh-logging --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --filename "${argocd_dir}/eck-operator-application.yaml"
kubectl -n elastic-system wait --for=condition=Available deployment/elastic-operator --timeout=300s
for attempt in {1..60}; do
  if kubectl get crd elasticsearches.elasticsearch.k8s.elastic.co kibanas.kibana.k8s.elastic.co >/dev/null 2>&1; then
    break
  fi
  if [ "${attempt}" -eq 60 ]; then
    echo "Timed out waiting for ECK CRDs." >&2
    exit 1
  fi
  sleep 5
done
kubectl apply --filename "${argocd_dir}/eck-logging-application.yaml"

application_manifests=(
  kiali-application.yaml
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
