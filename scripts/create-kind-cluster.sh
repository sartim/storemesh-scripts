#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workspace_dir="${STOREMESH_PLATFORM_DIR:-$(cd "${script_dir}/../.." && pwd)}"
cluster_config="${workspace_dir}/storemesh-kind-cluster/storemesh.yaml"
cluster_name="storemesh"

if ! command -v kind >/dev/null 2>&1; then
  echo "kind is required but was not found on PATH." >&2
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required but was not found on PATH." >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is required by Kind but was not found on PATH." >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker is installed but the Docker daemon is unavailable." >&2
  echo "Start Docker Desktop (or the local Docker daemon), then rerun this script." >&2
  exit 1
fi

if [ ! -f "${cluster_config}" ]; then
  echo "Kind configuration not found: ${cluster_config}" >&2
  echo "Set STOREMESH_PLATFORM_DIR to the directory containing the StoreMesh repositories." >&2
  exit 1
fi

if kind get clusters | grep -Fxq "${cluster_name}"; then
  echo "Kind cluster ${cluster_name} already exists."
else
  kind create cluster --config "${cluster_config}"
fi

kubectl wait \
  --for=condition=Ready \
  nodes \
  --all \
  --timeout=180s

echo "Kind cluster ${cluster_name} is ready."
