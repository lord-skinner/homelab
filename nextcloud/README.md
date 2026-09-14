# Nextcloud

Private Nextcloud deployment for `https://nas.home.datalab.gg`.

## Deploy

```bash
cp .env.example .env
# edit .env and set unique long passwords
./deploy.sh
```

The script creates/updates the `nextcloud-secrets` Kubernetes Secret and
applies the namespace, MariaDB, Redis, Nextcloud, Service, Ingress/HTTPRoute,
and cron
manifests.

The `nextcloud-data` PVC is backed by the NAS's `NetworkShare` Samba export.
The SMB CSI driver provisions a dedicated `nextcloud` subdirectory, leaving
the existing media files in the share untouched. The NAS share is configured
for guest access, so the deployment script creates the corresponding CSI
credential Secret without storing credentials in Git.

Do not delete the old FileBrowser PVCs until any data on them has been checked;
removing their manifests does not remove existing Kubernetes storage.
