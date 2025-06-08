#!/bin/bash
# Validation script for the Kubernetes control plane auto-provisioning system
set -euo pipefail

echo "🔍 Validating Kubernetes Control Plane Auto-Provisioning Setup"
echo "============================================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print status
print_status() {
    local status=$1
    local message=$2
    if [ "$status" == "ok" ]; then
        echo -e "${GREEN}✓${NC} $message"
    elif [ "$status" == "warning" ]; then
        echo -e "${YELLOW}⚠${NC} $message"
    else
        echo -e "${RED}✗${NC} $message"
    fi
}

# Check if scripts exist and are executable
echo -e "\n📋 Checking Script Files..."
scripts=(
    "control-plane-boot.sh"
    "k8s-control-plane-init.sh"
    "device-passthrough.sh"
    "manage-cluster.sh"
    "manage-machines.sh"
    "monitor-machines.sh"
)

for script in "${scripts[@]}"; do
    if [[ -f "$script" && -x "$script" ]]; then
        print_status "ok" "Script $script exists and is executable"
    else
        print_status "error" "Script $script is missing or not executable"
    fi
done

# Check documentation
echo -e "\n📚 Checking Documentation..."
if [[ -f "README.md" ]]; then
    print_status "ok" "README.md exists"
    if grep -q "Kubernetes Control Plane Auto-Provisioning" README.md; then
        print_status "ok" "README.md contains updated documentation"
    else
        print_status "warning" "README.md may need updating"
    fi
else
    print_status "error" "README.md is missing"
fi

# Check script syntax
echo -e "\n🔧 Checking Script Syntax..."
for script in "${scripts[@]}"; do
    if [[ -f "$script" ]]; then
        if bash -n "$script" 2>/dev/null; then
            print_status "ok" "Script $script has valid syntax"
        else
            print_status "error" "Script $script has syntax errors"
        fi
    fi
done

# Check required commands
echo -e "\n🛠️  Checking Required Commands..."
commands=(
    "curl"
    "wget"
    "jq"
    "systemctl"
    "nginx"
    "kubeadm"
    "kubectl"
    "docker"
)

for cmd in "${commands[@]}"; do
    if command -v "$cmd" >/dev/null 2>&1; then
        print_status "ok" "Command $cmd is available"
    else
        print_status "warning" "Command $cmd is not installed (may be installed during provisioning)"
    fi
done

# Check if running as root for full validation
if [[ $EUID -eq 0 ]]; then
    echo -e "\n🔐 Checking System Services (running as root)..."
    
    services=(
        "nginx"
        "tftpd-hpa"
        "isc-dhcp-server"
    )
    
    for service in "${services[@]}"; do
        if systemctl is-enabled "$service" >/dev/null 2>&1; then
            if systemctl is-active "$service" >/dev/null 2>&1; then
                print_status "ok" "Service $service is enabled and running"
            else
                print_status "warning" "Service $service is enabled but not running"
            fi
        else
            print_status "warning" "Service $service is not enabled (normal if not yet configured)"
        fi
    done
    
    # Check directories
    echo -e "\n📁 Checking System Directories..."
    directories=(
        "/srv/tftp"
        "/srv/http"
        "/srv/state"
        "/srv/http/machines"
        "/srv/http/scripts"
    )
    
    for dir in "${directories[@]}"; do
        if [[ -d "$dir" ]]; then
            print_status "ok" "Directory $dir exists"
        else
            print_status "warning" "Directory $dir does not exist (will be created during setup)"
        fi
    done
    
else
    print_status "warning" "Not running as root - skipping system service and directory checks"
    echo "  Run 'sudo ./validate-setup.sh' for complete validation"
fi

# Check network configuration
echo -e "\n🌐 Checking Network Configuration..."
if ip route | grep -q "10.0.0"; then
    print_status "ok" "Network appears to be configured for 10.0.0.x range"
else
    print_status "warning" "Network may need configuration for 10.0.0.x range"
fi

# Final summary
echo -e "\n📊 Validation Summary"
echo "====================="
echo "This validation checks the basic setup of the auto-provisioning system."
echo ""
echo "Next steps:"
echo "1. Update machine registry with actual MAC addresses"
echo "2. Run ./control-plane-boot.sh to set up the PXE server"
echo "3. Configure your network to use this server for DHCP/PXE"
echo "4. Boot your first control plane node"
echo "5. Monitor the process with ./monitor-machines.sh"
echo ""
echo "For detailed instructions, see README.md"
