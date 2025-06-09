#!/bin/bash
# Remote Deployment Wrapper for Control Plane Scripts
# This script helps deploy and execute control plane scripts on remote servers via SSH

set -euo pipefail

# Configuration
REMOTE_HOST="netboot@10.0.0.2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_TEMP_DIR="/tmp/homelab-provisioning"

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
    exit 1
}

usage() {
    echo "Remote Control Plane Deployment Script"
    echo ""
    echo "Usage: $0 [OPTIONS] {script_name|command}"
    echo ""
    echo "Options:"
    echo "  -h, --host HOST     Remote host (default: $REMOTE_HOST)"
    echo "  -u, --upload-only   Only upload scripts, don't execute"
    echo "  -c, --cleanup       Clean up remote temporary directory"
    echo "  --help              Show this help message"
    echo ""
    echo "Available Scripts:"
    echo "  control-plane-boot  - Sets up DHCP and TFTP server for network booting"
    echo "  k8s-control-plane   - Initialize Kubernetes control plane"
    echo "  manage-cluster      - Manage cluster operations"
    echo "  manage-machines     - Manage machine configurations"
    echo "  monitor-machines    - Monitor machine status"
    echo "  device-passthrough  - Configure device passthrough"
    echo "  validate-setup      - Validate the setup"
    echo ""
    echo "Commands:"
    echo "  upload              - Upload all scripts to remote host"
    echo "  status              - Check remote host status"
    echo "  logs                - View logs from remote host"
    echo ""
    echo "Examples:"
    echo "  $0 control-plane-boot"
    echo "  $0 -h user@10.0.0.3 k8s-control-plane"
    echo "  $0 upload"
    echo "  $0 --cleanup"
}

# Check SSH connectivity
check_ssh_connection() {
    log "Checking SSH connection to $REMOTE_HOST..."
    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$REMOTE_HOST" "echo 'SSH connection successful'" &>/dev/null; then
        error "Cannot connect to $REMOTE_HOST. Please check SSH configuration and host availability."
    fi
    log "SSH connection to $REMOTE_HOST is working"
}

# Upload scripts to remote host
upload_scripts() {
    log "Uploading scripts to $REMOTE_HOST:$REMOTE_TEMP_DIR..."
    
    # Create remote directory
    ssh "$REMOTE_HOST" "mkdir -p $REMOTE_TEMP_DIR"
    
    # Upload all shell scripts
    scp "$SCRIPT_DIR"/*.sh "$REMOTE_HOST:$REMOTE_TEMP_DIR/"
    
    # Upload README and other documentation
    if [ -f "$SCRIPT_DIR/README.md" ]; then
        scp "$SCRIPT_DIR/README.md" "$REMOTE_HOST:$REMOTE_TEMP_DIR/"
    fi
    
    if [ -f "$SCRIPT_DIR/QUICK_REFERENCE.md" ]; then
        scp "$SCRIPT_DIR/QUICK_REFERENCE.md" "$REMOTE_HOST:$REMOTE_TEMP_DIR/"
    fi
    
    # Make scripts executable
    ssh "$REMOTE_HOST" "chmod +x $REMOTE_TEMP_DIR/*.sh"
    
    log "Scripts uploaded successfully"
}

# Execute script on remote host
execute_remote_script() {
    local script_name="$1"
    shift
    local script_args="$@"
    
    local script_file=""
    case "$script_name" in
        "control-plane-boot")
            script_file="control-plane-boot.sh"
            ;;
        "k8s-control-plane")
            script_file="k8s-control-plane-init.sh"
            ;;
        "manage-cluster")
            script_file="manage-cluster.sh"
            ;;
        "manage-machines")
            script_file="manage-machines.sh"
            ;;
        "monitor-machines")
            script_file="monitor-machines.sh"
            ;;
        "device-passthrough")
            script_file="device-passthrough.sh"
            ;;
        "validate-setup")
            script_file="validate-setup.sh"
            ;;
        *)
            error "Unknown script: $script_name"
            ;;
    esac
    
    log "Executing $script_file on $REMOTE_HOST..."
    
    # Execute the script with proper error handling
    ssh "$REMOTE_HOST" "cd $REMOTE_TEMP_DIR && sudo bash $script_file $script_args" || {
        error "Script execution failed on remote host"
    }
    
    log "Script execution completed successfully"
}

# Get remote host status
get_remote_status() {
    log "Getting status from $REMOTE_HOST..."
    
    ssh "$REMOTE_HOST" "
        echo '=== System Information ==='
        uname -a
        echo ''
        echo '=== Disk Usage ==='
        df -h
        echo ''
        echo '=== Memory Usage ==='
        free -h
        echo ''
        echo '=== Service Status ==='
        systemctl is-active --quiet isc-dhcp-server && echo 'DHCP Server: Running' || echo 'DHCP Server: Not Running'
        systemctl is-active --quiet tftpd-hpa && echo 'TFTP Server: Running' || echo 'TFTP Server: Not Running'
        systemctl is-active --quiet nginx && echo 'Nginx: Running' || echo 'Nginx: Not Running'
        systemctl is-active --quiet kubelet && echo 'Kubelet: Running' || echo 'Kubelet: Not Running'
        echo ''
        if [ -f /etc/kubernetes/admin.conf ]; then
            echo '=== Kubernetes Status ==='
            export KUBECONFIG=/etc/kubernetes/admin.conf
            kubectl get nodes --no-headers 2>/dev/null | wc -l | xargs echo 'Nodes:'
            kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l | xargs echo 'Pods:'
        fi
    "
}

# View logs from remote host
view_remote_logs() {
    log "Viewing logs from $REMOTE_HOST..."
    
    ssh "$REMOTE_HOST" "
        echo '=== Recent System Logs ==='
        sudo journalctl --since '1 hour ago' --no-pager -n 50
        echo ''
        if [ -f /var/log/provision.log ]; then
            echo '=== Provisioning Logs ==='
            tail -50 /var/log/provision.log
        fi
    "
}

# Clean up remote temporary directory
cleanup_remote() {
    log "Cleaning up remote temporary directory..."
    ssh "$REMOTE_HOST" "rm -rf $REMOTE_TEMP_DIR"
    log "Cleanup completed"
}

# Parse command line arguments
UPLOAD_ONLY=false
CLEANUP=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--host)
            REMOTE_HOST="$2"
            shift 2
            ;;
        -u|--upload-only)
            UPLOAD_ONLY=true
            shift
            ;;
        -c|--cleanup)
            CLEANUP=true
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        -*)
            error "Unknown option: $1"
            ;;
        *)
            break
            ;;
    esac
done

# Handle cleanup
if [ "$CLEANUP" = true ]; then
    check_ssh_connection
    cleanup_remote
    exit 0
fi

# Check if command provided
if [ $# -eq 0 ]; then
    usage
    exit 1
fi

COMMAND="$1"
shift

# Main execution
check_ssh_connection

case "$COMMAND" in
    "upload")
        upload_scripts
        ;;
    "status")
        get_remote_status
        ;;
    "logs")
        view_remote_logs
        ;;
    "control-plane-boot"|"k8s-control-plane"|"manage-cluster"|"manage-machines"|"monitor-machines"|"device-passthrough"|"validate-setup")
        # Upload scripts first (unless upload-only)
        upload_scripts
        
        # Execute if not upload-only
        if [ "$UPLOAD_ONLY" = false ]; then
            execute_remote_script "$COMMAND" "$@"
        else
            log "Scripts uploaded. Use without --upload-only to execute."
        fi
        ;;
    *)
        error "Unknown command: $COMMAND. Use --help for usage information."
        ;;
esac

log "Remote deployment operation completed"
