#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  echo "OPENROUTER_API_KEY must be set" >&2
  exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

kubectl -n inference create secret generic openrouter-api-key \
  --from-literal=apiKey="$OPENROUTER_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$script_dir/openrouter-models.yaml"
kubectl apply -f "$script_dir/openrouter-backend-traffic-policy.yaml"
kubectl apply -f "$script_dir/ollama-models.yaml"
kubectl apply -f "$script_dir/openrouter-probe-exporter.yaml"
kubectl apply -f "$script_dir/openrouter-probe-exporter-deployment.yaml"
kubectl apply -f "$script_dir/openrouter-probe-podmonitor.yaml"
kubectl apply -f "$script_dir/openrouter-probe-prometheusrule.yaml"

kubectl -n inference wait --for=condition=Accepted \
  aiservicebackend/openrouter-north-mini-code \
  aiservicebackend/openrouter-gemma4-26b \
  aiservicebackend/openrouter-nemotron-omni \
  aiservicebackend/openrouter-ling-vl \
  aiservicebackend/openrouter-nex-n25-pro \
  aiservicebackend/openrouter-lfm25 \
  --timeout=120s
kubectl -n inference wait --for=condition=Accepted aigatewayroute/ollama-models --timeout=120s
kubectl -n inference rollout status deployment/openrouter-probe-exporter --timeout=120s

echo "OpenRouter free-model backends are reconciled."
