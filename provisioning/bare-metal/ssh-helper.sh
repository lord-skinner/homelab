#!/bin/bash
# SSH Configuration Helper for Homelab Control Plane
# Helps set up SSH keys and test connectivity to control plane servers

set -euo pipefail

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
    echo "SSH Configuration Helper for Homelab Control Plane"
    echo ""
    echo "Usage: $0 {setup-keys|test-connection|add-host} [host]"
    echo ""
    echo "Commands:"
    echo "  setup-keys [host]     - Generate and copy SSH keys to remote host"
    echo "  test-connection [host] - Test SSH connectivity to host"
    echo "  add-host [host]       - Add host to known_hosts"
    echo ""
    echo "Default host: netboot@10.0.0.2"
    echo ""
    echo "Examples:"
    echo "  $0 setup-keys netboot@10.0.0.2"
    echo "  $0 test-connection"
    echo "  $0 add-host netboot@10.0.0.3"
}

# Generate and copy SSH keys
setup_ssh_keys() {
    local host="${1:-netboot@10.0.0.2}"
    
    log "Setting up SSH keys for $host"
    
    # Generate SSH key if it doesn't exist
    if [ ! -f ~/.ssh/id_rsa ]; then
        log "Generating SSH key pair..."
        ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
    else
        log "SSH key already exists"
    fi
    
    # Copy public key to remote host
    log "Copying public key to $host..."
    if ssh-copy-id "$host"; then
        log "SSH key successfully copied to $host"
    else
        error "Failed to copy SSH key to $host"
    fi
    
    # Test the connection
    test_ssh_connection "$host"
}

# Test SSH connection
test_ssh_connection() {
    local host="${1:-netboot@10.0.0.2}"
    
    log "Testing SSH connection to $host..."
    
    if ssh -o ConnectTimeout=10 -o BatchMode=yes "$host" "echo 'SSH connection successful'" 2>/dev/null; then
        log "✅ SSH connection to $host is working"
        
        # Get some basic system info
        ssh "$host" "
            echo 'Host: $(hostname)'
            echo 'OS: $(lsb_release -d 2>/dev/null | cut -f2 || echo Unknown)'
            echo 'Kernel: $(uname -r)'
            echo 'IP: $(hostname -I | awk '{print \$1}')'
            echo 'Uptime: $(uptime -p)'
        "
    else
        error "❌ Cannot connect to $host via SSH"
        warn "Make sure:"
        warn "1. The host is reachable (try: ping ${host#*@})"
        warn "2. SSH service is running on the host"
        warn "3. You have the correct username and hostname"
        warn "4. SSH keys are properly configured (run: $0 setup-keys $host)"
    fi
}

# Add host to known_hosts
add_host_to_known_hosts() {
    local host="${1:-netboot@10.0.0.2}"
    local hostname="${host#*@}"
    
    log "Adding $hostname to known_hosts..."
    
    if ssh-keyscan -H "$hostname" >> ~/.ssh/known_hosts 2>/dev/null; then
        log "Host $hostname added to known_hosts"
    else
        error "Failed to add $hostname to known_hosts"
    fi
}

# Main execution
case "${1:-}" in
    "setup-keys")
        setup_ssh_keys "${2:-}"
        ;;
    "test-connection")
        test_ssh_connection "${2:-}"
        ;;
    "add-host")
        add_host_to_known_hosts "${2:-}"
        ;;
    "--help"|"-h"|"")
        usage
        ;;
    *)
        error "Unknown command: $1"
        usage
        exit 1
        ;;
esac
