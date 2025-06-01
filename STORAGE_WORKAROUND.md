# NFS Storage Temporary Workaround

This document outlines the temporary changes made to work around the unavailability of the NFS storage node.

## Changes Made

1. Modified deployment files to use `emptyDir` volumes instead of PersistentVolumeClaims:
   - `/home/skinner/homelab/blinko/postgres-deployment.yaml`
   - `/home/skinner/homelab/ollama/ollama-deployment.yaml`
   - `/home/skinner/homelab/n8n/postgres-deployment.yaml`

2. Removed PVC references from kustomization files:
   - `/home/skinner/homelab/blinko/kustomization.yaml`
   - `/home/skinner/homelab/ollama/kustomization.yaml`
   - `/home/skinner/homelab/n8n/kustomization.yaml`

3. Commented out the NFS provisioner and storage class configurations:
   - `/home/skinner/homelab/kube-system/nfs-provisioner-helm.yaml`
   - `/home/skinner/homelab/storage.yaml`

## Important Notes

- All data stored in these volumes is now temporary and will be lost when pods are restarted.
- For Postgres deployments, this means all database data will be lost on pod restart.
- For Ollama, models will need to be re-downloaded after pod restarts.

## Steps to Restore NFS Storage

Once the storage node is available again:

1. Uncomment the NFS provisioner and storage class configurations:
   - `/home/skinner/homelab/kube-system/nfs-provisioner-helm.yaml`
   - `/home/skinner/homelab/storage.yaml`

2. Apply the storage class and NFS provisioner:
   ```bash
   kubectl apply -f /home/skinner/homelab/storage.yaml
   kubectl apply -f /home/skinner/homelab/kube-system/nfs-provisioner-helm.yaml
   ```

3. Revert the deployment files to use PVCs instead of emptyDir:
   - Restore the original PVC reference in each deployment
   - Re-add the PVC files to the kustomization files

4. Apply the updated configurations:
   ```bash
   kubectl apply -k /home/skinner/homelab/blinko
   kubectl apply -k /home/skinner/homelab/ollama
   kubectl apply -k /home/skinner/homelab/n8n
   ```

5. For Postgres deployments, you'll need to restore data from backups if available.

## Data Restoration Recommendations

- For Postgres: Consider implementing a backup solution when storage is restored
- For Ollama: Cache downloaded models externally if they're large and time-consuming to download

*This file was created on June 1, 2025 as part of the temporary workaround for the unavailable NFS storage node.*
