# Kubernetes Setup Guide for Network-Booted Nodes

This guide provides instructions for setting up a Kubernetes cluster using network-booted nodes managed by the Raspberry Pi 3 network boot server.

## Prerequisites

1. Raspberry Pi 3 configured as a network boot server using the `setup-netboot.sh` script
2. Root filesystems prepared for each node using the `prepare-rootfs.sh` script
3. Network configuration properly set up for all nodes

## Architecture Overview

The cluster will consist of:

- **Raspberry Pi 3**: Network boot server (not part of the Kubernetes cluster)
- **Control Plane Node(s)**: Running Kubernetes control plane components
- **Worker Nodes**: Running workloads, mix of ARM and AMD architecture

## Step 1: Prepare Node Filesystems

For each node in your cluster, prepare a root filesystem:

```bash
# For an AMD64 worker node
sudo ./prepare-rootfs.sh amd worker1

# For an ARM64 worker node
sudo ./prepare-rootfs.sh arm worker2

# For a control plane node (typically AMD64)
sudo ./prepare-rootfs.sh amd master1
```

## Step 2: Configure Kubernetes Components

For each node, chroot into its filesystem and configure Kubernetes:

```bash
# Mount filesystems for chroot
NODE_ROOT="/srv/netboot/nfs/amd/master1"  # Adjust path as needed
sudo mount -t proc none ${NODE_ROOT}/proc
sudo mount -t sysfs none ${NODE_ROOT}/sys
sudo mount -o bind /dev ${NODE_ROOT}/dev
sudo mount -o bind /dev/pts ${NODE_ROOT}/dev/pts

# Copy the Kubernetes configuration script
sudo cp configure-k8s-node.sh ${NODE_ROOT}/tmp/

# Chroot and run the configuration script
sudo chroot ${NODE_ROOT} /bin/bash /tmp/configure-k8s-node.sh master 10.0.0.10 10.0.0.10

# Unmount when done
sudo umount ${NODE_ROOT}/dev/pts
sudo umount ${NODE_ROOT}/dev
sudo umount ${NODE_ROOT}/sys
sudo umount ${NODE_ROOT}/proc
```

Repeat for each worker node, using "worker" as the node type:

```bash
sudo chroot ${NODE_ROOT} /bin/bash /tmp/configure-k8s-node.sh worker 10.0.0.11 10.0.0.10
```

## Step 3: Boot the Control Plane Node

1. Power on the control plane node and ensure it network boots successfully
2. SSH into the node (using the IP address you configured)
3. Initialize the Kubernetes control plane:

```bash
sudo kubeadm init --config=/etc/kubernetes/kubeadm-init-config.yaml
```

4. Set up kubectl for the k8s user:

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

5. Install a CNI network plugin (e.g., Calico for multi-architecture support):

```bash
kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml
```

6. Get the join command for worker nodes:

```bash
kubeadm token create --print-join-command
```

## Step 4: Boot and Join Worker Nodes

1. Power on each worker node and ensure they network boot successfully
2. SSH into each worker node
3. Join the Kubernetes cluster using the token from the control plane:

```bash
# If using the helper script
/usr/local/bin/join-cluster.sh <token> <discovery_token_ca_cert_hash>

# Or directly with kubeadm
sudo kubeadm join 10.0.0.10:6443 --token <token> --discovery-token-ca-cert-hash <hash>
```

## Step 5: Verify Cluster Setup

From the control plane node, check that all nodes have joined the cluster:

```bash
kubectl get nodes -o wide
```

You should see all your nodes listed with their architecture.

## Multi-Architecture Considerations

### Node Labels

Add labels to identify node architectures:

```bash
# For ARM nodes
kubectl label nodes worker2 kubernetes.io/arch=arm64

# For AMD nodes
kubectl label nodes worker1 kubernetes.io/arch=amd64
```

### Node Selectors in Workloads

Use node selectors in your pod specs to target specific architectures:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: arm64-app
spec:
  template:
    spec:
      nodeSelector:
        kubernetes.io/arch: arm64
      containers:
        - name: app
          image: myapp:arm64
```

### Multi-Architecture Container Images

Use container images that support both architectures with manifest lists:

```bash
# Example for creating multi-arch images
docker buildx build --platform linux/amd64,linux/arm64 -t myapp:latest --push .
```

## Troubleshooting

### Kubelet Not Starting

Check kubelet logs:

```bash
journalctl -u kubelet
```

### Nodes Not Joining

Verify network connectivity:

```bash
ping <control_plane_ip>
telnet <control_plane_ip> 6443
```

### Pod Network Issues

Check CNI configuration:

```bash
kubectl get pods -n kube-system
```

## Advanced Configuration

### High Availability Control Plane

For production environments, set up multiple control plane nodes with a load balancer.

### Storage Classes

Configure storage classes appropriate for your environment:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
```

### Taints and Tolerations

Use taints to prevent workloads from scheduling on certain nodes:

```bash
# Taint control plane nodes
kubectl taint nodes master1 node-role.kubernetes.io/control-plane=:NoSchedule
```
