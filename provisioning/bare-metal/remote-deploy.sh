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
    echo "  stateless-boot      - Sets up stateless boot infrastructure (TFTP/HTTP/State API)"
    echo "  ssh-helper          - SSH configuration and connectivity helper"
    echo ""
    echo "Commands:"
    echo "  upload              - Upload all scripts to remote host"
    echo "  status              - Check remote host status"
    echo "  logs                - View logs from remote host"
    echo "  stateless-status    - Check stateless boot infrastructure status"
    echo "  ssh-test            - Test SSH connectivity"
    echo "  ssh-setup           - Setup SSH keys"
    echo ""
    echo "Examples:"
    echo "  $0 stateless-boot"
    echo "  $0 -h user@10.0.0.3 ssh-helper setup-keys"
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
    
    # Upload README and other documentation if they exist
    for doc_file in README.md QUICK_REFERENCE.md; do
        if [ -f "$SCRIPT_DIR/$doc_file" ]; then
            scp "$SCRIPT_DIR/$doc_file" "$REMOTE_HOST:$REMOTE_TEMP_DIR/"
        fi
    done
    
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
        "stateless-boot")
            script_file="stateless-boot-server.sh"
            ;;
        "ssh-helper")
            script_file="ssh-helper.sh"
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
        systemctl is-active --quiet tftpd-hpa && echo 'TFTP Server: Running' || echo 'TFTP Server: Not Running'
        systemctl is-active --quiet nginx && echo 'Nginx: Running' || echo 'Nginx: Not Running'
        systemctl is-active --quiet machine-state-api && echo 'State API: Running' || echo 'State API: Not Running'
        echo ''
        echo '=== Stateless Boot Infrastructure ==='
        [ -d /srv/tftp ] && echo 'TFTP Root: Available' || echo 'TFTP Root: Missing'
        [ -d /srv/http ] && echo 'HTTP Root: Available' || echo 'HTTP Root: Missing'
        [ -d /srv/state ] && echo 'State Root: Available' || echo 'State Root: Missing'
        [ -f /srv/http/machines/registry.json ] && echo 'Machine Registry: Available' || echo 'Machine Registry: Missing'
        [ -f /srv/state/machine-states.json ] && echo 'State Database: Available' || echo 'State Database: Missing'
        echo ''
        if [ -f /etc/kubernetes/admin.conf ]; then
            echo '=== Kubernetes Status ==='
            export KUBECONFIG=/etc/kubernetes/admin.conf
            kubectl get nodes --no-headers 2>/dev/null | wc -l | xargs echo 'Nodes:'
            kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l | xargs echo 'Pods:'
        else
            echo '=== Kubernetes Status ==='
            echo 'Kubernetes not configured on this host'
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

# Check stateless boot infrastructure status
check_stateless_status() {
    log "Checking stateless boot infrastructure status on $REMOTE_HOST..."
    
    ssh "$REMOTE_HOST" "
        echo '=== Stateless Boot Infrastructure Status ==='
        echo ''
        echo '📁 Directory Structure:'
        [ -d /srv/tftp ] && echo '✓ TFTP Root: /srv/tftp' || echo '✗ TFTP Root: Missing'
        [ -d /srv/http ] && echo '✓ HTTP Root: /srv/http' || echo '✗ HTTP Root: Missing'
        [ -d /srv/state ] && echo '✓ State Root: /srv/state' || echo '✗ State Root: Missing'
        [ -d /srv/http/machines ] && echo '✓ Machine Configs: /srv/http/machines' || echo '✗ Machine Configs: Missing'
        [ -d /srv/http/scripts ] && echo '✓ Scripts: /srv/http/scripts' || echo '✗ Scripts: Missing'
        [ -d /srv/http/cloud-init ] && echo '✓ Cloud-init: /srv/http/cloud-init' || echo '✗ Cloud-init: Missing'
        echo ''
        echo '📋 Configuration Files:'
        [ -f /srv/http/machines/registry.json ] && echo '✓ Machine Registry: Available' || echo '✗ Machine Registry: Missing'
        [ -f /srv/state/machine-states.json ] && echo '✓ State Database: Available' || echo '✗ State Database: Missing'
        [ -f /srv/tftp/pxelinux.cfg/default ] && echo '✓ PXE Config: Available' || echo '✗ PXE Config: Missing'
        [ -f /srv/tftp/grub/grub.cfg ] && echo '✓ GRUB Config: Available' || echo '✗ GRUB Config: Missing'
        echo ''
        echo '🔧 Services:'
        systemctl is-active --quiet tftpd-hpa && echo '✓ TFTP Server: Running' || echo '✗ TFTP Server: Not Running'
        systemctl is-active --quiet nginx && echo '✓ HTTP Server: Running' || echo '✗ HTTP Server: Not Running'
        systemctl is-active --quiet machine-state-api && echo '✓ State API: Running' || echo '✗ State API: Not Running'
        echo ''
        echo '🌐 Network Configuration:'
        ip addr show | grep 'inet 10.0.0' && echo '✓ Server IP configured' || echo '✗ Server IP not found'
        echo ''
        if [ -f /srv/http/machines/registry.json ]; then
            echo '📱 Registered Machines:'
            jq -r '.machines | to_entries[] | \"  - MAC: \" + .key + \", Host: \" + .value.hostname + \", IP: \" + .value.ip + \", Role: \" + .value.role' /srv/http/machines/registry.json 2>/dev/null || echo '  Error reading registry'
        fi
        echo ''
        if [ -f /srv/state/machine-states.json ]; then
            echo '📊 Machine State Summary:'
            python3 -c '
import json
try:
    with open(\"/srv/state/machine-states.json\", \"r\") as f:
        data = json.load(f)
    if data:
        states = {}
        for mac, info in data.items():
            state = info.get(\"state\", \"unknown\")
            states[state] = states.get(state, 0) + 1
        for state, count in states.items():
            print(f\"  {state}: {count}\")
    else:
        print(\"  No state data available\")
except Exception as e:
    print(f\"  Error reading state data: {e}\")
' 2>/dev/null || echo '  No state data available'
        fi
    "
}

# Execute SSH helper commands
execute_ssh_helper() {
    local subcommand="$1"
    shift
    local ssh_args="$@"
    
    log "Executing ssh-helper.sh $subcommand on $REMOTE_HOST..."
    
    # Execute ssh-helper with subcommand
    ssh "$REMOTE_HOST" "cd $REMOTE_TEMP_DIR && bash ssh-helper.sh $subcommand $ssh_args" || {
        error "SSH helper command failed on remote host"
    }
    
    log "SSH helper command completed successfully"
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
    "stateless-status")
        check_stateless_status
        ;;
    "ssh-test")
        log "Testing SSH connectivity to $REMOTE_HOST..."
        check_ssh_connection
        log "SSH connectivity test completed"
        ;;
    "ssh-setup")
        upload_scripts
        execute_ssh_helper "setup-keys" "$@"
        ;;
    "stateless-boot"|"ssh-helper")
        # Upload scripts first (unless upload-only)
        upload_scripts
        
        # Execute if not upload-only
        if [ "$UPLOAD_ONLY" = false ]; then
            if [ "$COMMAND" = "ssh-helper" ]; then
                execute_ssh_helper "$@"
            else
                execute_remote_script "$COMMAND" "$@"
            fi
        else
            log "Scripts uploaded. Use without --upload-only to execute."
        fi
        ;;
    *)
        error "Unknown command: $COMMAND. Use --help for usage information."
        ;;
esac

log "Remote deployment operation completed"