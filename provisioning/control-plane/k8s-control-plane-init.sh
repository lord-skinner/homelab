#!/bin/bash
# Kubernetes Control Plane Auto-Provisioning Script
# This script initializes and configures Kubernetes control plane nodes
set -euo pipefail

# Configuration
CLUSTER_NAME="homelab-k8s"
POD_SUBNET="192.168.0.0/16"
SERVICE_SUBNET="10.96.0.0/12"
API_SERVER_ENDPOINT="10.0.0.11:6443"
STATE_API_URL="http://10.0.0.10:8080"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
}

# Get machine information
get_machine_info() {
    MAC_ADDRESS=$(cat /sys/class/net/*/address | grep -v "00:00:00:00:00:00" | head -1)
    HOSTNAME=$(hostname)
    
    # Get configuration from state API
    CONFIG=$(curl -s "$STATE_API_URL/api/config/$MAC_ADDRESS" 2>/dev/null || echo '{}')
    ROLE=$(echo "$CONFIG" | jq -r '.role // "unknown"')
    FEATURES=$(echo "$CONFIG" | jq -r '.features[]? // empty' | tr '\n' ' ')
    IP=$(echo "$CONFIG" | jq -r '.ip // "unknown"')
    
    log "Machine Info: $HOSTNAME ($MAC_ADDRESS) - Role: $ROLE, IP: $IP"
    log "Features: $FEATURES"
}

# Report status to state API
report_status() {
    local state="$1"
    local message="$2"
    
    curl -X POST "$STATE_API_URL/api/state" \
        -H "Content-Type: application/json" \
        -d "{
            \"mac\": \"$MAC_ADDRESS\",
            \"hostname\": \"$HOSTNAME\",
            \"state\": \"$state\",
            \"message\": \"$message\",
            \"timestamp\": \"$(date -Iseconds)\"
        }" 2>/dev/null || true
}

# Save cluster data
save_cluster_data() {
    local key="$1"
    local value="$2"
    
    curl -X POST "$STATE_API_URL/api/data" \
        -H "Content-Type: application/json" \
        -d "{
            \"mac\": \"$MAC_ADDRESS\",
            \"key\": \"$key\",
            \"value\": \"$value\"
        }" 2>/dev/null || true
}

# Get cluster data
get_cluster_data() {
    local key="$1"
    curl -s "$STATE_API_URL/api/data/$MAC_ADDRESS/$key" 2>/dev/null | jq -r '.value // empty'
}

# Check if this is the first control plane node
is_first_control_plane() {
    # Check if cluster is already initialized by looking for existing kubeconfig
    if [ -f "/etc/kubernetes/admin.conf" ]; then
        return 1
    fi
    
    # Check if any other control plane has already initialized
    local existing_cluster=$(curl -s "$STATE_API_URL/api/states" 2>/dev/null | \
        jq -r '.states[]? | select(.state == "cluster-initialized") | .mac' | head -1)
    
    if [ -n "$existing_cluster" ]; then
        return 1
    fi
    
    return 0
}

# Initialize Kubernetes cluster (first control plane only)
initialize_cluster() {
    log "Initializing Kubernetes cluster as first control plane node"
    report_status "initializing" "Starting cluster initialization"
    
    # Create kubeadm config
    cat > /tmp/kubeadm-config.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v1.31.0
clusterName: $CLUSTER_NAME
controlPlaneEndpoint: $API_SERVER_ENDPOINT
networking:
  podSubnet: $POD_SUBNET
  serviceSubnet: $SERVICE_SUBNET
apiServer:
  advertiseAddress: $IP
  extraArgs:
    enable-admission-plugins: NodeRestriction
etcd:
  local:
    dataDir: /var/lib/etcd
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: $IP
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
  kubeletExtraArgs:
    node-labels: "node-role.kubernetes.io/control-plane=,homelab.io/node-type=control-plane,homelab.io/architecture=$(uname -m)"
    node-ip: $IP
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
containerRuntimeEndpoint: unix:///var/run/containerd/containerd.sock
EOF

    # Initialize cluster
    kubeadm init --config=/tmp/kubeadm-config.yaml --upload-certs
    
    # Setup kubectl for root
    mkdir -p /root/.kube
    cp /etc/kubernetes/admin.conf /root/.kube/config
    chown root:root /root/.kube/config
    
    # Setup kubectl for admin user if exists
    if id "admin" &>/dev/null; then
        mkdir -p /home/admin/.kube
        cp /etc/kubernetes/admin.conf /home/admin/.kube/config
        chown admin:admin /home/admin/.kube/config
    fi
    
    # Save cluster join tokens and certificates
    local join_token=$(kubeadm token list | grep -v TOKEN | head -1 | awk '{print $1}')
    local ca_cert_hash=$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | \
        openssl rsa -pubin -outform der 2>/dev/null | \
        openssl dgst -sha256 -hex | sed 's/^.* //')
    local cert_key=$(kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1)
    
    save_cluster_data "join-token" "$join_token"
    save_cluster_data "ca-cert-hash" "sha256:$ca_cert_hash"
    save_cluster_data "certificate-key" "$cert_key"
    save_cluster_data "cluster-endpoint" "$API_SERVER_ENDPOINT"
    
    log "Cluster initialized successfully"
    report_status "cluster-initialized" "Kubernetes cluster initialized"
}

# Join existing cluster as additional control plane
join_cluster() {
    log "Joining existing Kubernetes cluster as control plane node"
    report_status "joining" "Joining existing cluster"
    
    # Get join information from first control plane
    local join_token=""
    local ca_cert_hash=""
    local cert_key=""
    local cluster_endpoint=""
    
    # Wait for cluster data to be available
    local timeout=300
    local elapsed=0
    
    while [ $elapsed -lt $timeout ]; do
        join_token=$(curl -s "$STATE_API_URL/api/states" 2>/dev/null | \
            jq -r '.states[]? | select(.state == "cluster-initialized") | .mac' | head -1)
        
        if [ -n "$join_token" ]; then
            # Get the actual join data from the first control plane
            join_token=$(curl -s "$STATE_API_URL/api/data/$join_token/join-token" 2>/dev/null | jq -r '.value // empty')
            ca_cert_hash=$(curl -s "$STATE_API_URL/api/data/$join_token/ca-cert-hash" 2>/dev/null | jq -r '.value // empty')
            cert_key=$(curl -s "$STATE_API_URL/api/data/$join_token/certificate-key" 2>/dev/null | jq -r '.value // empty')
            cluster_endpoint=$(curl -s "$STATE_API_URL/api/data/$join_token/cluster-endpoint" 2>/dev/null | jq -r '.value // empty')
            
            if [ -n "$join_token" ] && [ -n "$ca_cert_hash" ] && [ -n "$cert_key" ]; then
                break
            fi
        fi
        
        log "Waiting for cluster initialization data... ($elapsed/$timeout seconds)"
        sleep 10
        elapsed=$((elapsed + 10))
    done
    
    if [ -z "$join_token" ]; then
        error "Failed to get cluster join information"
        report_status "error" "Failed to get cluster join information"
        exit 1
    fi
    
    # Create join config
    cat > /tmp/kubeadm-join-config.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: JoinConfiguration
discovery:
  bootstrapToken:
    token: $join_token
    apiServerEndpoint: $cluster_endpoint
    caCertHashes:
      - $ca_cert_hash
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
  kubeletExtraArgs:
    node-labels: "node-role.kubernetes.io/control-plane=,homelab.io/node-type=control-plane,homelab.io/architecture=$(uname -m)"
    node-ip: $IP
controlPlane:
  certificateKey: $cert_key
  localAPIEndpoint:
    advertiseAddress: $IP
    bindPort: 6443
EOF

    # Join cluster
    kubeadm join --config=/tmp/kubeadm-join-config.yaml
    
    # Setup kubectl
    mkdir -p /root/.kube
    cp /etc/kubernetes/admin.conf /root/.kube/config
    chown root:root /root/.kube/config
    
    if id "admin" &>/dev/null; then
        mkdir -p /home/admin/.kube
        cp /etc/kubernetes/admin.conf /home/admin/.kube/config
        chown admin:admin /home/admin/.kube/config
    fi
    
    log "Successfully joined cluster as control plane node"
    report_status "cluster-joined" "Joined cluster as control plane"
}

# Configure container runtime for device passthrough
configure_container_runtime() {
    log "Configuring container runtime for device passthrough"
    
    # Configure containerd for GPU support if GPU feature is enabled
    if echo "$FEATURES" | grep -q "gpu"; then
        log "Configuring containerd for GPU support"
        
        # Create containerd config directory
        mkdir -p /etc/containerd
        
        # Generate default config and modify for NVIDIA
        containerd config default > /etc/containerd/config.toml
        
        # Enable nvidia runtime
        sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
        
        # Add NVIDIA runtime configuration
        cat >> /etc/containerd/config.toml <<EOF

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia]
  privileged_without_host_devices = false
  runtime_engine = ""
  runtime_root = ""
  runtime_type = "io.containerd.runc.v2"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia.options]
    BinaryName = "/usr/bin/nvidia-container-runtime"
    SystemdCgroup = true
EOF
        
        systemctl restart containerd
        log "GPU support configured for containerd"
    fi
    
    # Configure for NFS storage if NFS feature is enabled
    if echo "$FEATURES" | grep -q "nfs"; then
        log "Configuring NFS support"
        apt-get install -y nfs-common
        log "NFS client support installed"
    fi
}

# Install and configure CNI (Calico)
install_cni() {
    log "Installing Calico CNI"
    report_status "installing-cni" "Installing network CNI"
    
    # Wait for API server to be ready
    while ! kubectl get nodes &>/dev/null; do
        log "Waiting for API server to be ready..."
        sleep 5
    done
    
    # Install Calico
    kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml
    
    # Configure Calico with custom IP pool
    cat > /tmp/calico-config.yaml <<EOF
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - blockSize: 26
      cidr: $POD_SUBNET
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF
    
    kubectl create -f /tmp/calico-config.yaml
    
    # Wait for Calico to be ready
    log "Waiting for Calico to be ready..."
    kubectl wait --for=condition=Ready pods -l k8s-app=calico-node -n calico-system --timeout=300s
    
    log "Calico CNI installed successfully"
}

# Apply node taints and labels based on machine configuration
configure_node_scheduling() {
    log "Configuring node scheduling (taints and labels)"
    
    local node_name=$(kubectl get nodes --no-headers | grep "$IP" | awk '{print $1}')
    
    if [ -z "$node_name" ]; then
        warn "Could not find node in cluster, retrying..."
        sleep 10
        node_name=$(kubectl get nodes --no-headers | grep "$IP" | awk '{print $1}')
    fi
    
    if [ -z "$node_name" ]; then
        error "Failed to find node in cluster"
        return 1
    fi
    
    log "Configuring node: $node_name"
    
    # Apply base labels
    kubectl label node "$node_name" homelab.io/hostname="$HOSTNAME" --overwrite
    kubectl label node "$node_name" homelab.io/mac="$MAC_ADDRESS" --overwrite
    kubectl label node "$node_name" homelab.io/provisioned="$(date -Iseconds)" --overwrite
    
    # Configure based on features
    for feature in $FEATURES; do
        case "$feature" in
            "gpu")
                log "Configuring GPU node scheduling"
                kubectl label node "$node_name" homelab.io/gpu=true --overwrite
                kubectl label node "$node_name" nvidia.com/gpu=true --overwrite
                # Taint for GPU workloads only
                kubectl taint node "$node_name" homelab.io/gpu=true:NoSchedule --overwrite || true
                ;;
            "nfs")
                log "Configuring NFS storage node"
                kubectl label node "$node_name" homelab.io/nfs-server=true --overwrite
                kubectl label node "$node_name" homelab.io/storage=true --overwrite
                ;;
            "storage")
                log "Configuring storage node"
                kubectl label node "$node_name" homelab.io/storage=true --overwrite
                ;;
        esac
    done
    
    # Apply control plane specific configuration
    kubectl label node "$node_name" homelab.io/control-plane=true --overwrite
    
    log "Node scheduling configuration complete"
}

# Install cluster add-ons
install_addons() {
    log "Installing cluster add-ons"
    report_status "installing-addons" "Installing cluster add-ons"
    
    # Install metrics server
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
    
    # Patch metrics server for local cluster
    kubectl patch deployment metrics-server -n kube-system --type='json' \
        -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'
    
    # Install NVIDIA GPU Operator if GPU nodes exist
    if echo "$FEATURES" | grep -q "gpu"; then
        log "Installing NVIDIA GPU Operator"
        kubectl create namespace gpu-operator-system || true
        helm repo add nvidia https://helm.ngc.nvidia.com/nvidia || true
        helm repo update
        helm upgrade --install gpu-operator nvidia/gpu-operator \
            --namespace gpu-operator-system \
            --create-namespace \
            --set operator.defaultRuntime=containerd
    fi
    
    log "Add-ons installation complete"
}

# Main execution
main() {
    log "Starting Kubernetes Control Plane Auto-Provisioning"
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        error "This script must be run as root"
        exit 1
    fi
    
    # Get machine information
    get_machine_info
    
    # Verify this is a control plane node
    if [ "$ROLE" != "control-plane" ]; then
        error "This script is only for control plane nodes. Current role: $ROLE"
        exit 1
    fi
    
    report_status "k8s-provisioning" "Starting Kubernetes control plane setup"
    
    # Configure container runtime
    configure_container_runtime
    
    # Initialize or join cluster
    if is_first_control_plane; then
        initialize_cluster
        
        # Install CNI (only on first node)
        install_cni
        
        # Install add-ons (only on first node)
        install_addons
    else
        join_cluster
    fi
    
    # Configure node scheduling
    configure_node_scheduling
    
    # Final status report
    report_status "k8s-ready" "Kubernetes control plane ready"
    log "Kubernetes control plane provisioning complete!"
    
    # Display cluster info
    log "Cluster Status:"
    kubectl get nodes -o wide
    kubectl get pods -A
}

# Handle script arguments
case "${1:-main}" in
    "main"|"")
        main
        ;;
    "init-only")
        get_machine_info
        configure_container_runtime
        initialize_cluster
        install_cni
        install_addons
        ;;
    "join-only")
        get_machine_info
        configure_container_runtime
        join_cluster
        ;;
    "configure-only")
        get_machine_info
        configure_node_scheduling
        ;;
    *)
        echo "Usage: $0 [main|init-only|join-only|configure-only]"
        exit 1
        ;;
esac
