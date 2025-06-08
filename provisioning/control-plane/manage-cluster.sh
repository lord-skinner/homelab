#!/bin/bash
# Control Plane Management Script
# Manage Kubernetes control plane nodes and cluster operations
set -euo pipefail

# Configuration
STATE_API_URL="http://10.0.0.10:8080"
KUBECONFIG="/root/.kube/config"

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

usage() {
    echo "Control Plane Management Script"
    echo ""
    echo "Usage: $0 {status|nodes|pods|init|join|reset|backup|restore|upgrade} [options]"
    echo ""
    echo "Commands:"
    echo "  status              - Show cluster status"
    echo "  nodes               - Show node information with labels and taints"
    echo "  pods                - Show pod distribution across nodes"
    echo "  init                - Force re-initialize cluster (DANGEROUS)"
    echo "  join TOKEN          - Generate join command for new nodes"
    echo "  reset               - Reset this node (DANGEROUS)"
    echo "  backup [path]       - Backup cluster configuration"
    echo "  restore [path]      - Restore cluster configuration"
    echo "  upgrade             - Upgrade cluster components"
    echo "  drain NODE          - Drain a node for maintenance"
    echo "  uncordon NODE       - Mark node as schedulable"
    echo "  devices             - Show device passthrough status"
    echo ""
    echo "Examples:"
    echo "  $0 status"
    echo "  $0 nodes"
    echo "  $0 backup /backup/cluster-$(date +%Y%m%d)"
    echo "  $0 drain k8s-cp-2"
}

# Check if kubectl is available and cluster is accessible
check_kubectl() {
    if ! command -v kubectl >/dev/null 2>&1; then
        error "kubectl not found. Is Kubernetes installed?"
        exit 1
    fi
    
    if ! kubectl cluster-info >/dev/null 2>&1; then
        error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
}

# Show cluster status
show_status() {
    log "Kubernetes Cluster Status"
    echo ""
    
    echo -e "${BLUE}Cluster Info:${NC}"
    kubectl cluster-info
    echo ""
    
    echo -e "${BLUE}Node Status:${NC}"
    kubectl get nodes -o wide
    echo ""
    
    echo -e "${BLUE}Control Plane Components:${NC}"
    kubectl get pods -n kube-system -l tier=control-plane
    echo ""
    
    echo -e "${BLUE}Cluster Resources:${NC}"
    kubectl top nodes 2>/dev/null || echo "Metrics server not available"
    echo ""
    
    echo -e "${BLUE}Storage Classes:${NC}"
    kubectl get storageclass
    echo ""
    
    # Show machine states from API
    echo -e "${BLUE}Machine States:${NC}"
    curl -s "$STATE_API_URL/api/states" 2>/dev/null | \
        jq -r '.states[]? | select(.state | contains("k8s")) | "\(.hostname): \(.state) - \(.message)"' || \
        echo "State API not available"
}

# Show detailed node information
show_nodes() {
    log "Detailed Node Information"
    echo ""
    
    echo -e "${BLUE}Nodes with Labels and Taints:${NC}"
    kubectl get nodes --show-labels
    echo ""
    
    for node in $(kubectl get nodes --no-headers | awk '{print $1}'); do
        echo -e "${YELLOW}Node: $node${NC}"
        echo "Labels:"
        kubectl get node "$node" -o jsonpath='{.metadata.labels}' | jq -r 'to_entries[] | "  \(.key): \(.value)"'
        echo "Taints:"
        kubectl get node "$node" -o jsonpath='{.spec.taints}' | jq -r '.[]? | "  \(.key): \(.value) (\(.effect))"' || echo "  None"
        echo "Capacity:"
        kubectl get node "$node" -o jsonpath='{.status.capacity}' | jq -r 'to_entries[] | "  \(.key): \(.value)"'
        echo ""
    done
}

# Show pod distribution
show_pods() {
    log "Pod Distribution Across Nodes"
    echo ""
    
    echo -e "${BLUE}Pods by Node:${NC}"
    kubectl get pods -A -o wide --sort-by='.spec.nodeName'
    echo ""
    
    echo -e "${BLUE}Pod Count by Node:${NC}"
    kubectl get pods -A -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | \
        sort | uniq -c | sort -nr
    echo ""
    
    echo -e "${BLUE}Pods by Namespace:${NC}"
    kubectl get pods -A | awk 'NR>1 {print $1}' | sort | uniq -c | sort -nr
}

# Generate join command
generate_join() {
    local token_ttl="${1:-24h}"
    
    log "Generating join commands (TTL: $token_ttl)"
    
    # Generate new token
    local token=$(kubeadm token create --ttl="$token_ttl")
    local ca_hash=$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | \
        openssl rsa -pubin -outform der 2>/dev/null | \
        openssl dgst -sha256 -hex | sed 's/^.* //')
    local endpoint=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed 's|https://||')
    
    echo ""
    echo -e "${GREEN}Worker Node Join Command:${NC}"
    echo "kubeadm join $endpoint --token $token --discovery-token-ca-cert-hash sha256:$ca_hash"
    echo ""
    
    # Generate control plane join if certificates are available
    if [ -f "/etc/kubernetes/pki/ca.key" ]; then
        local cert_key=$(kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1)
        echo -e "${GREEN}Control Plane Join Command:${NC}"
        echo "kubeadm join $endpoint --token $token --discovery-token-ca-cert-hash sha256:$ca_hash --control-plane --certificate-key $cert_key"
        echo ""
    fi
    
    echo -e "${YELLOW}Token expires in: $token_ttl${NC}"
}

# Backup cluster configuration
backup_cluster() {
    local backup_path="${1:-/backup/cluster-$(date +%Y%m%d-%H%M%S)}"
    
    log "Backing up cluster to: $backup_path"
    
    mkdir -p "$backup_path"
    
    # Backup etcd
    log "Backing up etcd..."
    ETCDCTL_API=3 etcdctl snapshot save "$backup_path/etcd-snapshot.db" \
        --endpoints=https://127.0.0.1:2379 \
        --cacert=/etc/kubernetes/pki/etcd/ca.crt \
        --cert=/etc/kubernetes/pki/etcd/server.crt \
        --key=/etc/kubernetes/pki/etcd/server.key
    
    # Backup certificates
    log "Backing up certificates..."
    cp -r /etc/kubernetes/pki "$backup_path/"
    
    # Backup kubeadm config
    log "Backing up kubeadm config..."
    kubectl get configmap kubeadm-config -n kube-system -o yaml > "$backup_path/kubeadm-config.yaml"
    
    # Backup all manifests
    log "Backing up cluster manifests..."
    mkdir -p "$backup_path/manifests"
    kubectl get all -A -o yaml > "$backup_path/manifests/all-resources.yaml"
    
    # Backup custom resources
    for crd in $(kubectl get crd --no-headers | awk '{print $1}'); do
        kubectl get "$crd" -A -o yaml > "$backup_path/manifests/$crd.yaml" 2>/dev/null || true
    done
    
    log "Backup completed: $backup_path"
    du -sh "$backup_path"
}

# Show device passthrough status
show_devices() {
    log "Device Passthrough Status"
    echo ""
    
    echo -e "${BLUE}GPU Devices:${NC}"
    nvidia-smi 2>/dev/null || echo "No NVIDIA GPUs detected"
    echo ""
    
    echo -e "${BLUE}GPU Pods:${NC}"
    kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].resources.limits.nvidia\.com/gpu}{"\n"}{end}' | \
        grep -v "^.*\t$" || echo "No GPU pods found"
    echo ""
    
    echo -e "${BLUE}Storage Classes:${NC}"
    kubectl get storageclass
    echo ""
    
    echo -e "${BLUE}Persistent Volumes:${NC}"
    kubectl get pv
    echo ""
    
    echo -e "${BLUE}NFS Exports (if available):${NC}"
    showmount -e localhost 2>/dev/null || echo "NFS server not running"
}

# Drain node for maintenance
drain_node() {
    local node="$1"
    
    if [ -z "$node" ]; then
        error "Node name required"
        exit 1
    fi
    
    log "Draining node: $node"
    kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --force
    log "Node $node drained successfully"
}

# Mark node as schedulable
uncordon_node() {
    local node="$1"
    
    if [ -z "$node" ]; then
        error "Node name required"
        exit 1
    fi
    
    log "Uncordoning node: $node"
    kubectl uncordon "$node"
    log "Node $node is now schedulable"
}

# Upgrade cluster components
upgrade_cluster() {
    log "Starting cluster upgrade process"
    warn "This will upgrade cluster components. Ensure you have backups!"
    
    read -p "Continue with upgrade? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Upgrade cancelled"
        exit 0
    fi
    
    # Update package lists
    apt-get update
    
    # Check available versions
    log "Available kubeadm versions:"
    apt-cache madison kubeadm | head -5
    
    read -p "Enter target version (e.g., 1.31.1-1.1): " version
    
    if [ -z "$version" ]; then
        error "Version required"
        exit 1
    fi
    
    # Upgrade kubeadm
    log "Upgrading kubeadm to $version"
    apt-mark unhold kubeadm
    apt-get install -y kubeadm="$version"
    apt-mark hold kubeadm
    
    # Plan upgrade
    log "Planning upgrade..."
    kubeadm upgrade plan
    
    read -p "Apply upgrade? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        kubeadm upgrade apply "v${version%-*}"
        
        # Upgrade kubelet and kubectl
        log "Upgrading kubelet and kubectl"
        apt-mark unhold kubelet kubectl
        apt-get install -y kubelet="$version" kubectl="$version"
        apt-mark hold kubelet kubectl
        
        systemctl daemon-reload
        systemctl restart kubelet
        
        log "Upgrade completed successfully"
    else
        log "Upgrade cancelled"
    fi
}

# Reset cluster (DANGEROUS)
reset_cluster() {
    warn "This will completely reset the Kubernetes cluster!"
    warn "All workloads and data will be lost!"
    
    read -p "Type 'RESET' to confirm: " confirm
    if [ "$confirm" != "RESET" ]; then
        log "Reset cancelled"
        exit 0
    fi
    
    log "Resetting cluster..."
    kubeadm reset --force
    rm -rf /root/.kube
    
    log "Cluster reset completed"
}

# Main execution
case "${1:-}" in
    "status")
        check_kubectl
        show_status
        ;;
    "nodes")
        check_kubectl
        show_nodes
        ;;
    "pods")
        check_kubectl
        show_pods
        ;;
    "join")
        check_kubectl
        generate_join "${2:-24h}"
        ;;
    "backup")
        check_kubectl
        backup_cluster "$2"
        ;;
    "devices")
        show_devices
        ;;
    "drain")
        check_kubectl
        drain_node "$2"
        ;;
    "uncordon")
        check_kubectl
        uncordon_node "$2"
        ;;
    "upgrade")
        check_kubectl
        upgrade_cluster
        ;;
    "reset")
        reset_cluster
        ;;
    *)
        usage
        exit 1
        ;;
esac
