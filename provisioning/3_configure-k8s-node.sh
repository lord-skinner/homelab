#!/bin/bash
#
# Kubernetes Node Configuration Script
# 
# This script prepares a network-booted node to join a Kubernetes cluster.
# It should be run in the chroot environment of the node's root filesystem.
#
# Usage: ./configure-k8s-node.sh <node_type> <node_ip> <control_plane_ip>

# Example:
# sudo chroot /srv/netboot/nfs/amd/master1 /bin/bash /tmp/configure-k8s-node.sh master 10.0.0.10 10.0.0.10
# sudo chroot /srv/netboot/nfs/arm/worker1 /bin/bash /tmp/configure-k8s-node.sh worker 10.0.0.11 10.0.0.10
#

set -e
set -o pipefail

# Text formatting
BOLD="\033[1m"
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

# Function to print colored messages
log() {
  local level="$1"
  local message="$2"
  
  case "$level" in
    "info")
      echo -e "${BLUE}[INFO]${RESET} $message"
      ;;
    "success")
      echo -e "${GREEN}[SUCCESS]${RESET} $message"
      ;;
    "warn")
      echo -e "${YELLOW}[WARNING]${RESET} $message"
      ;;
    "error")
      echo -e "${RED}[ERROR]${RESET} $message"
      ;;
    *)
      echo -e "$message"
      ;;
  esac
}

# Check for correct number of arguments
if [ "$#" -lt 3 ]; then
  echo "Usage: $0 <node_type> <node_ip> <control_plane_ip>"
  echo "  node_type: master or worker"
  echo "  node_ip: IP address of this node"
  echo "  control_plane_ip: IP address of the Kubernetes control plane"
  exit 1
fi

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  log "error" "This script must be run as root."
  exit 1
fi

NODE_TYPE=$1
NODE_IP=$2
CONTROL_PLANE_IP=$3
K8S_VERSION="1.27.0-00"  # Specify the Kubernetes version

# Validate node type
if [[ ! "$NODE_TYPE" =~ ^(master|worker)$ ]]; then
  log "error" "Node type must be either 'master' or 'worker'"
  exit 1
fi

# Install container runtime (containerd)
log "info" "Installing containerd..."
apt-get update
apt-get install -y ca-certificates curl gnupg

# Add Docker's official GPG key
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# Add Docker repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install containerd
apt-get update
apt-get install -y containerd.io

# Configure containerd to use systemd cgroup driver
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml > /dev/null
sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml

# Restart containerd
systemctl restart containerd
systemctl enable containerd

# Install Kubernetes components
log "info" "Installing Kubernetes components (version ${K8S_VERSION})..."

# Add Kubernetes GPG key
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.27/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Add Kubernetes repository
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.27/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list

# Install kubelet, kubeadm, and kubectl
apt-get update
apt-get install -y kubelet=${K8S_VERSION} kubeadm=${K8S_VERSION} kubectl=${K8S_VERSION}
apt-mark hold kubelet kubeadm kubectl

# Configure kubelet for network boot specifics
cat > /etc/default/kubelet << EOF
KUBELET_EXTRA_ARGS="--fail-swap-on=false --node-ip=${NODE_IP}"
EOF

# Create kubeadm configuration
mkdir -p /etc/kubernetes
cat > /etc/kubernetes/kubeadm-config.yaml << EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: ${CONTROL_PLANE_IP}:6443
    unsafeSkipCAVerification: true
    # Note: You'll need to provide the actual token and discovery token CA cert hash
    # token: abcdef.0123456789abcdef
    # caCertHashes:
    # - sha256:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
nodeRegistration:
  name: $(hostname)
  kubeletExtraArgs:
    node-ip: ${NODE_IP}
EOF

if [ "$NODE_TYPE" = "master" ]; then
  log "info" "Configuring as a control plane node..."
  
  # Additional configuration for control plane nodes
  cat > /etc/kubernetes/kubeadm-init-config.yaml << EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${NODE_IP}
  bindPort: 6443
nodeRegistration:
  name: $(hostname)
  kubeletExtraArgs:
    node-ip: ${NODE_IP}
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
networking:
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
controlPlaneEndpoint: ${CONTROL_PLANE_IP}:6443
EOF

  log "info" "To initialize the control plane, run:"
  log "info" "kubeadm init --config=/etc/kubernetes/kubeadm-init-config.yaml"
else
  log "info" "Configured as a worker node."
  log "info" "To join the cluster, you need to run a command like:"
  log "info" "kubeadm join ${CONTROL_PLANE_IP}:6443 --token <token> --discovery-token-ca-cert-hash <hash>"
fi

# Create a helper script to join the cluster
cat > /usr/local/bin/join-cluster.sh << 'EOF'
#!/bin/bash

# This script helps join this node to a Kubernetes cluster

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <token> <discovery_token_ca_cert_hash>"
  echo "  token: The bootstrap token (e.g., abcdef.0123456789abcdef)"
  echo "  discovery_token_ca_cert_hash: The hash of the CA cert (e.g., sha256:xxx...)"
  exit 1
fi

TOKEN=$1
HASH=$2

# Update the kubeadm config with the token and hash
sed -i "s/# token: .*/  token: ${TOKEN}/g" /etc/kubernetes/kubeadm-config.yaml
sed -i "s/# caCertHashes:/  caCertHashes:/g" /etc/kubernetes/kubeadm-config.yaml
sed -i "s/# - sha256:.*/  - ${HASH}/g" /etc/kubernetes/kubeadm-config.yaml

# Join the cluster
kubeadm join --config=/etc/kubernetes/kubeadm-config.yaml
EOF
chmod +x /usr/local/bin/join-cluster.sh

# Set SELinux to permissive mode
if command -v setenforce &> /dev/null; then
  log "info" "Setting SELinux to permissive mode..."
  setenforce 0
  sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
fi

# Disable swap (Kubernetes requirement)
log "info" "Disabling swap..."
swapoff -a
sed -i '/swap/d' /etc/fstab

# Final instructions
log "success" "Kubernetes node configuration complete!"
log "info" "Node type: ${NODE_TYPE}"
log "info" "Node IP: ${NODE_IP}"
log "info" "Control plane IP: ${CONTROL_PLANE_IP}"

if [ "$NODE_TYPE" = "master" ]; then
  log "info" "To initialize the control plane, run:"
  log "info" "kubeadm init --config=/etc/kubernetes/kubeadm-init-config.yaml"
  log "info" "After initialization, make sure to set up a CNI network plugin like Calico or Flannel."
else
  log "info" "To join the cluster, get the join command from the master node and run:"
  log "info" "/usr/local/bin/join-cluster.sh <token> <discovery_token_ca_cert_hash>"
fi

exit 0
