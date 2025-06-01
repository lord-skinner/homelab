#!/bin/bash
# restore-storage.sh - Script to restore NFS storage configuration

echo "Restoring NFS storage configuration..."

# Uncomment NFS provisioner and storage class configurations
sed -i 's/^# \(apiVersion: .*\)/\1/g' /home/skinner/homelab/kube-system/nfs-provisioner-helm.yaml
sed -i 's/^# \(kind: .*\)/\1/g' /home/skinner/homelab/kube-system/nfs-provisioner-helm.yaml
sed -i 's/^# \(metadata:\)/\1/g' /home/skinner/homelab/kube-system/nfs-provisioner-helm.yaml
sed -i 's/^# \(  name: .*\)/\1/g' /home/skinner/homelab/kube-system/nfs-provisioner-helm.yaml
sed -i 's/^# \(  namespace: .*\)/\1/g' /home/skinner/homelab/kube-system/nfs-provisioner-helm.yaml
sed -i 's/^# \(spec:\)/\1/g' /home/skinner/homelab/kube-system/nfs-provisioner-helm.yaml
sed -i 's/^# \(  chart: .*\)/\1/g' /home/skinner/homelab/kube-system/nfs-provisioner-helm.yaml
sed -i 's/^# \(  repo: .*\)/\1/g' /home/skinner/homelab/kube-system/nfs-provisioner-helm.yaml
sed -i 's/^# \(  set:\)/\1/g' /home/skinner/homelab/kube-system/nfs-provisioner-helm.yaml
sed -i 's/^# \(    nfs\..*\)/\1/g' /home/skinner/homelab/kube-system/nfs-provisioner-helm.yaml
sed -i 's/^# \(    storageClass\..*\)/\1/g' /home/skinner/homelab/kube-system/nfs-provisioner-helm.yaml

sed -i 's/^# \(allowVolumeExpansion: .*\)/\1/g' /home/skinner/homelab/storage.yaml
sed -i 's/^# \(apiVersion: .*\)/\1/g' /home/skinner/homelab/storage.yaml
sed -i 's/^# \(kind: .*\)/\1/g' /home/skinner/homelab/storage.yaml
sed -i 's/^# \(metadata:\)/\1/g' /home/skinner/homelab/storage.yaml
sed -i 's/^# \(  annotations:\)/\1/g' /home/skinner/homelab/storage.yaml
sed -i 's/^# \(    meta\..*\)/\1/g' /home/skinner/homelab/storage.yaml
sed -i 's/^# \(  labels:\)/\1/g' /home/skinner/homelab/storage.yaml
sed -i 's/^# \(    app: .*\)/\1/g' /home/skinner/homelab/storage.yaml
sed -i 's/^# \(    app\.kubernetes\.io\/.*\)/\1/g' /home/skinner/homelab/storage.yaml
sed -i 's/^# \(    chart: .*\)/\1/g' /home/skinner/homelab/storage.yaml
sed -i 's/^# \(    heritage: .*\)/\1/g' /home/skinner/homelab/storage.yaml
sed -i 's/^# \(    release: .*\)/\1/g' /home/skinner/homelab/storage.yaml
sed -i 's/^# \(  name: .*\)/\1/g' /home/skinner/homelab/storage.yaml
sed -i 's/^# \(parameters:\)/\1/g' /home/skinner/homelab/storage.yaml
sed -i 's/^# \(  archiveOnDelete: .*\)/\1/g' /home/skinner/homelab/storage.yaml
sed -i 's/^# \(  onDelete: .*\)/\1/g' /home/skinner/homelab/storage.yaml
sed -i 's/^# \(  pathPattern: .*\)/\1/g' /home/skinner/homelab/storage.yaml
sed -i 's/^# \(provisioner: .*\)/\1/g' /home/skinner/homelab/storage.yaml
sed -i 's/^# \(reclaimPolicy: .*\)/\1/g' /home/skinner/homelab/storage.yaml
sed -i 's/^# \(volumeBindingMode: .*\)/\1/g' /home/skinner/homelab/storage.yaml

# Restore deployment files to use PVCs instead of emptyDir
# Blinko
sed -i 's/emptyDir: {}/persistentVolumeClaim:\n            claimName: postgres-pvc/g' /home/skinner/homelab/blinko/postgres-deployment.yaml
# Add PVC back to kustomization.yaml
sed -i '/postgres-service.yaml/i\  - postgres-pvc.yaml' /home/skinner/homelab/blinko/kustomization.yaml

# Ollama
sed -i 's/emptyDir: {}/persistentVolumeClaim:\n          claimName: ollama/g' /home/skinner/homelab/ollama/ollama-deployment.yaml
# Add PVC back to kustomization.yaml
sed -i '/ollama-service.yaml/a\  - ollama-pvc.yaml' /home/skinner/homelab/ollama/kustomization.yaml

# N8N
sed -i 's/emptyDir: {}/persistentVolumeClaim:\n            claimName: postgres-pvc/g' /home/skinner/homelab/n8n/postgres-deployment.yaml
# Add PVC back to kustomization.yaml
sed -i '/postgres-init-script.yaml/a\  - postgres-pvc.yaml' /home/skinner/homelab/n8n/kustomization.yaml

echo "Configuration restored. Now applying changes..."

# Apply the changes
kubectl apply -f /home/skinner/homelab/storage.yaml
kubectl apply -f /home/skinner/homelab/kube-system/nfs-provisioner-helm.yaml

# Wait for the provisioner to be ready
echo "Waiting for NFS provisioner to be ready..."
sleep 30

# Apply the applications
kubectl apply -k /home/skinner/homelab/blinko
kubectl apply -k /home/skinner/homelab/ollama
kubectl apply -k /home/skinner/homelab/n8n

echo "Storage configuration has been restored."
echo "IMPORTANT: Remember that you'll need to restore your database data and Ollama models."
echo "See STORAGE_WORKAROUND.md for more information."
