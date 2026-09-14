# SMB CSI driver

The cluster uses the upstream SMB CSI driver to mount the NAS share from
Kubernetes nodes. The driver is installed in `kube-system` with Helm:

```bash
helm repo add csi-driver-smb https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/master/charts
helm repo update
helm upgrade --install csi-driver-smb csi-driver-smb/csi-driver-smb \
  --version 1.20.3 \
  --namespace kube-system \
  --set image.repository=registry.k8s.io/sig-storage/csi-smb \
  --wait
```

`nextcloud/smb-storageclass.yaml` uses the CSI driver to provision the
`nextcloud` subdirectory of `//192.168.0.242/NetworkShare`.
