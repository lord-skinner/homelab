#!/usr/bin/env bash

set -euo pipefail

ECK_VERSION=3.5.0
ECK_BASE_URL="https://download.elastic.co/downloads/eck/${ECK_VERSION}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

kubectl apply -f "$ECK_BASE_URL/crds.yaml"
kubectl apply -f "$ECK_BASE_URL/operator.yaml"
kubectl -n elastic-system rollout status statefulset/elastic-operator --timeout=180s

kubectl apply -f "$REPO_ROOT/elastic/namespace.yaml"
kubectl apply -f "$REPO_ROOT/elastic/elasticsearch.yaml"
kubectl apply -f "$REPO_ROOT/elastic/kibana.yaml"
kubectl apply -f "$REPO_ROOT/elastic/agent-rbac.yaml"
kubectl apply -f "$REPO_ROOT/elastic/agent.yaml"
kubectl apply -f "$REPO_ROOT/elastic/ingress.yaml"
kubectl apply -f "$REPO_ROOT/elastic/kibana-httproute.yaml"

echo "Elastic Stack resources applied. Monitor with:"
echo "  kubectl -n elastic-stack get elasticsearch,kibana,agent,pods"
