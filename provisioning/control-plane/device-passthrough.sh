#!/bin/bash
# Device Passthrough Configuration for Kubernetes Nodes
# Handles GPU, NFS, and storage device passthrough
set -euo pipefail

# Configuration
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
    FEATURES=$(echo "$CONFIG" | jq -r '.features[]? // empty' | tr '\n' ' ')
    SPECS=$(echo "$CONFIG" | jq -r '.specs // {}')
    
    log "Configuring device passthrough for: $HOSTNAME"
    log "Features: $FEATURES"
}

# Configure GPU passthrough
configure_gpu_passthrough() {
    log "Configuring GPU passthrough"
    
    # Detect NVIDIA GPUs
    local gpu_count=$(lspci | grep -i nvidia | wc -l)
    if [ "$gpu_count" -eq 0 ]; then
        warn "No NVIDIA GPUs detected"
        return 0
    fi
    
    log "Found $gpu_count NVIDIA GPU(s)"
    
    # Install NVIDIA drivers
    log "Installing NVIDIA drivers"
    apt-get update
    apt-get install -y nvidia-driver-535 nvidia-utils-535
    
    # Install NVIDIA Container Toolkit
    log "Installing NVIDIA Container Toolkit"
    distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    
    apt-get update
    apt-get install -y nvidia-container-toolkit
    
    # Configure containerd for NVIDIA
    nvidia-ctk runtime configure --runtime=containerd
    systemctl restart containerd
    
    # Create device plugin manifest
    mkdir -p /etc/kubernetes/manifests
    cat > /etc/kubernetes/manifests/nvidia-device-plugin.yaml <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvidia-device-plugin-daemonset
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: nvidia-device-plugin-ds
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        name: nvidia-device-plugin-ds
    spec:
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
      - key: homelab.io/gpu
        operator: Exists
        effect: NoSchedule
      nodeSelector:
        homelab.io/gpu: "true"
      priorityClassName: "system-node-critical"
      containers:
      - image: nvcr.io/nvidia/k8s-device-plugin:v0.14.3
        name: nvidia-device-plugin-ctr
        args: ["--fail-on-init-error=false"]
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
        volumeMounts:
          - name: device-plugin
            mountPath: /var/lib/kubelet/device-plugins
      volumes:
        - name: device-plugin
          hostPath:
            path: /var/lib/kubelet/device-plugins
      hostNetwork: true
EOF
    
    log "GPU passthrough configuration complete"
}

# Configure NFS storage passthrough
configure_nfs_passthrough() {
    log "Configuring NFS storage passthrough"
    
    # Install NFS server
    apt-get install -y nfs-kernel-server nfs-common
    
    # Create NFS export directories
    mkdir -p /srv/nfs/shared
    mkdir -p /srv/nfs/persistent-volumes
    mkdir -p /srv/nfs/backups
    
    # Configure exports
    cat > /etc/exports <<EOF
# NFS exports for Kubernetes cluster
/srv/nfs/shared         *(rw,sync,no_subtree_check,no_root_squash,no_all_squash)
/srv/nfs/persistent-volumes *(rw,sync,no_subtree_check,no_root_squash,no_all_squash)
/srv/nfs/backups        *(rw,sync,no_subtree_check,no_root_squash,no_all_squash)
EOF
    
    # Set permissions
    chown -R nobody:nogroup /srv/nfs
    chmod -R 755 /srv/nfs
    
    # Enable and start NFS server
    systemctl enable nfs-kernel-server
    systemctl restart nfs-kernel-server
    exportfs -ra
    
    log "NFS server configured and started"
    
    # Create NFS StorageClass manifest
    mkdir -p /tmp/k8s-manifests
    cat > /tmp/k8s-manifests/nfs-storage-class.yaml <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-storage
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: nfs.csi.k8s.io
parameters:
  server: $(hostname -I | awk '{print $1}')
  share: /srv/nfs/persistent-volumes
reclaimPolicy: Retain
volumeBindingMode: Immediate
EOF
    
    log "NFS storage passthrough configuration complete"
}

# Configure block storage passthrough
configure_storage_passthrough() {
    log "Configuring block storage passthrough"
    
    # Detect storage devices
    local storage_devices=$(lsblk -nd -o NAME,SIZE,TYPE | grep disk | grep -v loop)
    log "Available storage devices:"
    echo "$storage_devices"
    
    # Install LVM tools
    apt-get install -y lvm2
    
    # Create directories for local storage
    mkdir -p /mnt/local-storage
    
    # Configure local storage for Kubernetes
    cat > /tmp/k8s-manifests/local-storage-class.yaml <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
EOF
    
    log "Storage passthrough configuration complete"
}

# Configure USB device passthrough (for specialized hardware)
configure_usb_passthrough() {
    log "Configuring USB device passthrough"
    
    # Install USB utilities
    apt-get install -y usbutils
    
    # List USB devices
    log "Available USB devices:"
    lsusb
    
    # Create device plugin for USB devices if needed
    # This is a placeholder for custom USB device handling
    
    log "USB device detection complete"
}

# Configure network device passthrough (for network acceleration)
configure_network_passthrough() {
    log "Configuring network device passthrough"
    
    # Install SR-IOV tools if applicable
    if lspci | grep -i "virtual function" >/dev/null; then
        log "SR-IOV capable network devices detected"
        apt-get install -y pciutils
        
        # Enable SR-IOV if supported
        # This would need specific configuration per network card
        log "SR-IOV network passthrough available"
    fi
    
    # Configure for high-performance networking
    cat >> /etc/sysctl.conf <<EOF
# Network performance tuning for Kubernetes
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.core.netdev_max_backlog = 5000
EOF
    
    sysctl -p
    
    log "Network device configuration complete"
}

# Create device monitoring script
create_device_monitor() {
    log "Creating device monitoring script"
    
    cat > /usr/local/bin/monitor-devices.sh <<'EOF'
#!/bin/bash
# Device monitoring script for Kubernetes nodes
set -euo pipefail

LOG_FILE="/var/log/device-monitor.log"

log_message() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

check_gpu() {
    if command -v nvidia-smi >/dev/null 2>&1; then
        local gpu_status=$(nvidia-smi --query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null || echo "ERROR")
        if [ "$gpu_status" != "ERROR" ]; then
            log_message "GPU Status: $gpu_status"
            # Report to state API if available
            # curl -X POST http://10.0.0.10:8080/api/metrics ...
        else
            log_message "GPU Status: Error reading GPU metrics"
        fi
    fi
}

check_storage() {
    local disk_usage=$(df -h | grep -E '^/dev/' | awk '{print $1 ": " $5 " used"}')
    log_message "Storage Usage: $disk_usage"
}

check_network() {
    local network_stats=$(ip -s link show | grep -A1 "state UP" | grep -E 'RX:|TX:' | head -2)
    log_message "Network Stats: $network_stats"
}

# Main monitoring loop
while true; do
    check_gpu
    check_storage
    check_network
    sleep 60
done
EOF
    
    chmod +x /usr/local/bin/monitor-devices.sh
    
    # Create systemd service for device monitoring
    cat > /etc/systemd/system/device-monitor.service <<EOF
[Unit]
Description=Device Monitor for Kubernetes Node
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/monitor-devices.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl enable device-monitor
    systemctl start device-monitor
    
    log "Device monitoring service created and started"
}

# Apply device-specific Kubernetes manifests
apply_device_manifests() {
    log "Applying device-specific Kubernetes manifests"
    
    # Wait for kubectl to be available
    while ! command -v kubectl >/dev/null 2>&1; do
        log "Waiting for kubectl to be available..."
        sleep 5
    done
    
    # Wait for cluster to be ready
    while ! kubectl get nodes >/dev/null 2>&1; do
        log "Waiting for Kubernetes cluster to be ready..."
        sleep 5
    done
    
    # Apply manifests if they exist
    if [ -d "/tmp/k8s-manifests" ]; then
        for manifest in /tmp/k8s-manifests/*.yaml; do
            if [ -f "$manifest" ]; then
                log "Applying manifest: $manifest"
                kubectl apply -f "$manifest" || warn "Failed to apply $manifest"
            fi
        done
    fi
    
    log "Device manifests applied"
}

# Main execution
main() {
    log "Starting device passthrough configuration"
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        error "This script must be run as root"
        exit 1
    fi
    
    # Get machine information
    get_machine_info
    
    # Configure devices based on features
    for feature in $FEATURES; do
        case "$feature" in
            "gpu")
                configure_gpu_passthrough
                ;;
            "nfs")
                configure_nfs_passthrough
                ;;
            "storage")
                configure_storage_passthrough
                ;;
        esac
    done
    
    # Always configure these
    configure_usb_passthrough
    configure_network_passthrough
    
    # Create monitoring
    create_device_monitor
    
    # Apply Kubernetes manifests (run in background to avoid blocking)
    (sleep 30 && apply_device_manifests) &
    
    log "Device passthrough configuration complete"
}

# Handle script arguments
case "${1:-main}" in
    "main"|"")
        main
        ;;
    "gpu")
        get_machine_info
        configure_gpu_passthrough
        ;;
    "nfs")
        get_machine_info
        configure_nfs_passthrough
        ;;
    "storage")
        get_machine_info
        configure_storage_passthrough
        ;;
    "monitor")
        create_device_monitor
        ;;
    *)
        echo "Usage: $0 [main|gpu|nfs|storage|monitor]"
        exit 1
        ;;
esac
