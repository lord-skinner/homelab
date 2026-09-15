#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
kubectl apply -f "$SCRIPT_DIR/namespace.yaml"
kubectl apply -f "$SCRIPT_DIR/site-config.yaml"
kubectl apply -f "$SCRIPT_DIR/deployment.yaml"
kubectl apply -f "$SCRIPT_DIR/httproute.yaml"
kubectl -n docs-site rollout status deployment/docs --timeout=180s
kubectl -n docs-site get deployment,service
kubectl -n docs-site get httproute docs -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status}{"\n"}{end}'
echo "Docs site applied: https://docs.home.datalab.gg/"
