#!/usr/bin/env bash

set -euo pipefail

RELEASE=agent-router
CRD_RELEASE=agent-router-crds
NAMESPACE=envoy-ai-gateway-system
CRD_CHART=oci://docker.io/envoyproxy/ai-gateway-crds-helm
CHART=oci://docker.io/envoyproxy/ai-gateway-helm
VERSION=v1.1.0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

command -v helm >/dev/null 2>&1 || { echo "helm is required" >&2; exit 2; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required" >&2; exit 2; }

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install "$CRD_RELEASE" "$CRD_CHART" \
  --namespace "$NAMESPACE" \
  --version "$VERSION" \
  --wait \
  --timeout 10m

helm upgrade --install "$RELEASE" "$CHART" \
  --namespace "$NAMESPACE" \
  --version "$VERSION" \
  --values "$SCRIPT_DIR/values.yaml" \
  --wait \
  --timeout 10m

kubectl -n "$NAMESPACE" rollout status deployment/ai-gateway-controller --timeout=5m
helm status "$RELEASE" --namespace "$NAMESPACE"

# Enable the Envoy Gateway extension manager only after its target Service is
# present, avoiding a broken xDS hook during the intermediate install state.
helm upgrade --install envoy-gateway oci://docker.io/envoyproxy/gateway-helm \
  --namespace envoy-gateway-system \
  --version v1.9.1 \
  --values "$REPO_ROOT/infrastructure/envoy-gateway/values.yaml" \
  --values "$REPO_ROOT/infrastructure/envoy-gateway/values-agent-router.yaml" \
  --wait \
  --timeout 10m

kubectl -n envoy-gateway-system rollout status deployment/envoy-gateway --timeout=5m

echo "Agent Router $VERSION is ready and Envoy Gateway AI integration is enabled."
echo "Apply Ollama model routes with:"
echo "  $SCRIPT_DIR/apply-ollama-models.sh"
