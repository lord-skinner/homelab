#!/usr/bin/env bash

set -euo pipefail

RELEASE=envoy-gateway
NAMESPACE=envoy-gateway-system
CHART=oci://docker.io/envoyproxy/gateway-helm
VERSION=v1.9.1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v helm >/dev/null 2>&1 || { echo "helm is required" >&2; exit 2; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required" >&2; exit 2; }

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$SCRIPT_DIR/controller-endpointslice-rbac.yaml"

# K3s may already provide Gateway API CRDs. Applying the exact pinned chart
# CRDs upgrades them in place without making Helm fight the K3s HelmChart.
# Helm may print OCI pull metadata to stdout before the YAML stream. Start at
# the first Kubernetes object so kubectl never receives that metadata.
helm show crds "$CHART" --version "$VERSION" \
  | sed -n '/^apiVersion:/,$p' \
  | kubectl apply --server-side --force-conflicts -f -

helm_values=(--values "$SCRIPT_DIR/values.yaml")
if kubectl -n envoy-ai-gateway-system get service ai-gateway-controller >/dev/null 2>&1; then
  helm_values+=(--values "$SCRIPT_DIR/values-agent-router.yaml")
fi

helm upgrade --install "$RELEASE" "$CHART" \
  --namespace "$NAMESPACE" \
  --version "$VERSION" \
  "${helm_values[@]}" \
  --wait \
  --timeout 10m

kubectl -n "$NAMESPACE" rollout status deployment/envoy-gateway --timeout=5m
helm status "$RELEASE" --namespace "$NAMESPACE"

echo "Envoy Gateway $VERSION is ready. Apply Gateway API resources with:"
echo "  $SCRIPT_DIR/apply-home-ingress.sh"
