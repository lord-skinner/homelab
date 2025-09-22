#!/bin/bash

# Script to create Kubernetes secrets from .env file
# This ensures secrets are not hardcoded in the repository

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load environment variables from .env file
if [ -f "$SCRIPT_DIR/.env" ]; then
    export $(grep -v '^#' "$SCRIPT_DIR/.env" | xargs)
    echo "✓ Loaded environment variables from .env file"
else
    echo "❌ Error: .env file not found!"
    echo "Please copy .env.template to .env and configure your secrets"
    exit 1
fi

# Validate required environment variables
required_vars=("N8N_POSTGRES_DB" "N8N_POSTGRES_USER" "N8N_POSTGRES_PASSWORD" "N8N_ENCRYPTION_KEY")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "❌ Error: Required environment variable $var is not set"
        exit 1
    fi
done

echo "✓ All required environment variables are set"

# Create the namespace if it doesn't exist
kubectl create namespace n8n --dry-run=client -o yaml | kubectl apply -f -

# Create or update the Kubernetes secret
kubectl create secret generic n8n-postgres-secret \
    --namespace=n8n \
    --from-literal=N8N_POSTGRES_DB="$N8N_POSTGRES_DB" \
    --from-literal=N8N_POSTGRES_USER="$N8N_POSTGRES_USER" \
    --from-literal=N8N_POSTGRES_PASSWORD="$N8N_POSTGRES_PASSWORD" \
    --from-literal=N8N_ENCRYPTION_KEY="$N8N_ENCRYPTION_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "✓ Kubernetes secret 'n8n-postgres-secret' created/updated successfully"

# Apply other Kubernetes manifests (excluding the old secret file)
echo "Applying Kubernetes manifests..."
for file in "$SCRIPT_DIR"/*.yaml; do
    if [[ "$(basename "$file")" != "n8n-postgres-secret.yaml" ]]; then
        echo "Applying $(basename "$file")..."
        kubectl apply -f "$file"
    fi
done

echo "✅ n8n deployment completed successfully!"
echo ""
echo "To access n8n:"
echo "  kubectl port-forward -n n8n service/n8n 5678:5678"
echo "  Then visit: http://localhost:5678"