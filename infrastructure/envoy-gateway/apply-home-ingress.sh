#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

kubectl apply -f "$SCRIPT_DIR/home-ingress.yaml"
kubectl apply -f "$SCRIPT_DIR/client-traffic-policy.yaml"
kubectl apply -f "$REPO_ROOT/n8n/n8n-httproute.yaml"
kubectl apply -f "$REPO_ROOT/nextcloud/nextcloud-httproute.yaml"
kubectl apply -f "$REPO_ROOT/elastic/kibana-httproute.yaml"
kubectl apply -f "$SCRIPT_DIR/home-ingress-redirect-httproute.yaml"
kubectl apply -f "$SCRIPT_DIR/envoy-proxy-podmonitor.yaml"

echo "Gateway and HTTPRoutes applied. The staging Tailscale hostname is home-ingress-envoy."
