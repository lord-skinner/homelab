#!/bin/bash

# Setup script for deploying GenAI Toolbox

set -e

# Check if .env file exists
if [ ! -f .env ]; then
  echo "Error: .env file not found."
  echo "Please create a .env file with GOOGLE_API_KEY=your_api_key_here"
  exit 1
fi

# Source the .env file
source .env

# Check if GOOGLE_API_KEY is set
if [ -z "$GOOGLE_API_KEY" ] || [ "$GOOGLE_API_KEY" = "your_api_key_here" ]; then
  echo "Error: GOOGLE_API_KEY is not set or is still using the default value."
  echo "Please update the GOOGLE_API_KEY value in the .env file."
  exit 1
fi

# Check if namespace exists
if ! kubectl get namespace genai-toolbox &>/dev/null; then
  echo "Creating genai-toolbox namespace..."
  kubectl apply -f namespace.yaml
else
  echo "Namespace genai-toolbox already exists."
fi

# Create or update the API key secret
echo "Creating/updating Google API key secret..."
kubectl create secret generic google-api-key --from-literal=api-key="$GOOGLE_API_KEY" -n genai-toolbox --dry-run=client -o yaml | kubectl apply -f -

# Apply all resources
echo "Applying GenAI Toolbox resources..."
kubectl apply -k .

echo "Waiting for deployment to be ready..."
kubectl rollout status deployment/genai-toolbox -n genai-toolbox

echo
echo "GenAI Toolbox has been deployed successfully!"
echo "You can access it within your cluster at: http://genai-toolbox.genai-toolbox.svc.cluster.local:8080"
echo
echo "To use it with n8n, create HTTP requests to this service address."
