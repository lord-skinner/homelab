#!/bin/bash

# Apply the kustomization
kubectl apply -k .

echo "Joplin deployment has been applied"
echo "===================================="
echo "Joplin Server is available at: http://NODE_IP:30443"
echo ""
echo "Initial setup instructions:"
echo "1. Navigate to http://NODE_IP:30443"
echo "2. Create an admin account"
echo "3. Use the Joplin desktop app or web clipper to connect to your server"
echo ""
echo "To check the status, run: kubectl get pods -n joplin"
