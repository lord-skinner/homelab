#!/bin/bash
# apply-temporary-config.sh - Script to apply the temporary configuration without persistent storage

echo "Applying temporary configuration without persistent storage..."

# Apply the applications with temporary storage
kubectl apply -k /home/skinner/homelab/blinko
kubectl apply -k /home/skinner/homelab/ollama
kubectl apply -k /home/skinner/homelab/n8n

echo "Temporary configuration has been applied."
echo "IMPORTANT: All data in these applications will be temporary and will be lost when pods are restarted."
echo "See STORAGE_WORKAROUND.md for more information."
