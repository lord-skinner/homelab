#!/usr/bin/env bash

set -euo pipefail

NAMESPACE=elastic-stack
RELEASE=prometheus
CHART_VERSION=90.1.1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community
kubectl get namespace "$NAMESPACE" >/dev/null

# Prometheus Operator expects separate Secret keys for the username and
# password. ECK's generated Secret contains only the elastic user's password.
elastic_password="$(kubectl -n "$NAMESPACE" get secret elasticsearch-es-elastic-user \
  -o jsonpath='{.data.elastic}' | base64 --decode)"
kubectl -n "$NAMESPACE" create secret generic prometheus-elasticsearch-auth \
  --from-literal=username=elastic \
  --from-literal=password="$elastic_password" \
  --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install "$RELEASE" prometheus-community/kube-prometheus-stack \
  --namespace "$NAMESPACE" \
  --version "$CHART_VERSION" \
  --values "$SCRIPT_DIR/values.yaml" \
  --wait \
  --timeout 10m

echo "Prometheus installed without Grafana or Alertmanager."
echo "Metrics are remote-written to Elasticsearch and explored in Kibana."
