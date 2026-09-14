#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

kubectl apply -f "$REPO_ROOT/inference/namespace.yaml"
kubectl apply -f "$SCRIPT_DIR/ollama-models.yaml"

echo "Applied the Ollama model catalog and Agent Router route."
