#!/usr/bin/env bash

set -euo pipefail

RELEASE=semantic-router
NAMESPACE=vllm-semantic-router-system
CHART=oci://ghcr.io/vllm-project/charts/semantic-router
VERSION=0.3.0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v helm >/dev/null 2>&1 || { echo "helm is required" >&2; exit 2; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required" >&2; exit 2; }

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install "$RELEASE" "$CHART" \
  --namespace "$NAMESPACE" \
  --version "$VERSION" \
  --values "$SCRIPT_DIR/values.yaml" \
  --wait \
  --timeout 30m

kubectl -n "$NAMESPACE" rollout status deployment/semantic-router --timeout=30m
kubectl apply -f "$SCRIPT_DIR/podmonitor.yaml"
kubectl apply -f "$SCRIPT_DIR/poddisruptionbudget.yaml"
helm status "$RELEASE" --namespace "$NAMESPACE"

echo "Semantic Router $VERSION is ready. Apply its Envoy ExtProc policy with:"
echo "  kubectl apply -f $SCRIPT_DIR/envoypatchpolicy.yaml"
