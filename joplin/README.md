# Joplin Server Deployment

This directory contains Kubernetes manifests for deploying Joplin Server in your homelab.

## Components

1. **PostgreSQL Database** - Stores all Joplin data
2. **Joplin Server** - The backend server for synchronizing notes

## Accessing Joplin

Joplin Server is accessible at: http://[YOUR-NODE-IP]:30443

## Setup Instructions

1. Run the setup script to deploy Joplin:
   ```
   ./setup.sh
   ```

2. Navigate to http://[YOUR-NODE-IP]:30443 in your browser
   
3. On first access, you'll need to create an admin account

4. Download the Joplin desktop application from https://joplinapp.org/

5. In the Joplin desktop app:
   - Go to Tools > Options > Synchronization
   - Select "Joplin Server" as the synchronization target
   - Enter the server URL: http://[YOUR-NODE-IP]:30443
   - Enter your credentials
   - Click "Check synchronization configuration"

## Maintenance

Check the status of your Joplin deployment:
```
kubectl get pods -n joplin
```

View logs:
```
kubectl logs -n joplin deployment/joplin-server
kubectl logs -n joplin deployment/joplin-postgres
```

## Persistent Storage

Joplin uses two PVCs:
- `joplin-data-pvc` (2Gi) - For Joplin server data
- `joplin-postgres-pvc` (1Gi) - For PostgreSQL database

## Security Notes

This deployment uses:
- Basic authentication
- Default PostgreSQL credentials (defined in the manifests)
- NodePort for external access

For production use, consider:
- Using secrets for database credentials
- Setting up an Ingress with HTTPS
- Regular backups of your data
