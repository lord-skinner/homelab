#!/bin/bash
# Script to set up a PXE boot environment for network booting
# ARM server (10.0.0.2) serving AMD64 UEFI clients with Ubuntu netboot images

set -euo pipefail

# Configuration
PXE_SERVER_IP="10.0.0.2"
TFTP_ROOT="/srv/tftp"
UBUNTU_VERSION="24.04"
UBUNTU_CODENAME="noble"
NETBOOT_URL="http://releases.ubuntu.com/24.04/"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

install_packages() {
    log_info "Installing required packages..."
    apt update
    apt install -y tftpd-hpa wget curl unzip
}

setup_tftp_directories() {
    log_info "Setting up TFTP directory structure..."
    
    # Create main TFTP directories
    mkdir -p "${TFTP_ROOT}"/{ubuntu,grub,pxelinux.cfg}
    mkdir -p "${TFTP_ROOT}/ubuntu/${UBUNTU_VERSION}/amd64"
    
    # Set proper permissions
    chown -R tftp:tftp "${TFTP_ROOT}"
    chmod -R 755 "${TFTP_ROOT}"
}

configure_tftp_server() {
    log_info "Configuring TFTP server..."
    
    # Backup original config
    cp /etc/default/tftpd-hpa /etc/default/tftpd-hpa.backup
    
    # Configure TFTP server
    cat > /etc/default/tftpd-hpa << EOF
# /etc/default/tftpd-hpa
TFTP_USERNAME="tftp"
TFTP_DIRECTORY="${TFTP_ROOT}"
TFTP_ADDRESS="${PXE_SERVER_IP}:69"
TFTP_OPTIONS="--secure --create"
EOF
}

download_ubuntu_netboot() {
    log_info "Downloading Ubuntu ${UBUNTU_VERSION} netboot images for AMD64..."
    
    local download_dir="${TFTP_ROOT}/ubuntu/${UBUNTU_VERSION}/amd64"
    
    # Download netboot tarball (using latest available version)
    wget -O /tmp/netboot.tar.gz "${NETBOOT_URL}ubuntu-24.04.2-netboot-amd64.tar.gz"
    
    # Extract to the appropriate directory
    cd "${download_dir}"
    tar -xzf /tmp/netboot.tar.gz
    
    # Clean up
    rm /tmp/netboot.tar.gz
    
    log_info "Netboot files extracted to ${download_dir}"
}

setup_grub_config() {
    log_info "Setting up GRUB configuration for UEFI boot..."
    
    # Create grub.cfg for UEFI boot
    cat > "${TFTP_ROOT}/grub/grub.cfg" << 'EOF'
set timeout=30
set default=0

menuentry "Ubuntu 24.04 Install" {
    linux ubuntu/24.04/amd64/ubuntu-installer/amd64/linux
    initrd ubuntu/24.04/amd64/ubuntu-installer/amd64/initrd.gz
}

menuentry "Ubuntu 24.04 Install (text mode)" {
    linux ubuntu/24.04/amd64/ubuntu-installer/amd64/linux text
    initrd ubuntu/24.04/amd64/ubuntu-installer/amd64/initrd.gz
}

menuentry "Ubuntu 24.04 Rescue Mode" {
    linux ubuntu/24.04/amd64/ubuntu-installer/amd64/linux rescue/enable=true
    initrd ubuntu/24.04/amd64/ubuntu-installer/amd64/initrd.gz
}
EOF

    # Copy grub UEFI bootloader
    if [ -f "${TFTP_ROOT}/ubuntu/${UBUNTU_VERSION}/amd64/bootnetx64.efi" ]; then
        cp "${TFTP_ROOT}/ubuntu/${UBUNTU_VERSION}/amd64/bootnetx64.efi" "${TFTP_ROOT}/"
        log_info "UEFI bootloader copied to TFTP root"
    else
        log_warn "UEFI bootloader not found in netboot image"
    fi
}

setup_pxelinux_config() {
    log_info "Setting up PXELinux configuration..."
    
    # Create default PXELinux configuration
    cat > "${TFTP_ROOT}/pxelinux.cfg/default" << 'EOF'
DEFAULT ubuntu-install
TIMEOUT 300
PROMPT 1

LABEL ubuntu-install
    MENU LABEL Ubuntu 24.04 Install
    KERNEL ubuntu/24.04/amd64/ubuntu-installer/amd64/linux
    APPEND initrd=ubuntu/24.04/amd64/ubuntu-installer/amd64/initrd.gz

LABEL ubuntu-install-text
    MENU LABEL Ubuntu 24.04 Install (Text Mode)
    KERNEL ubuntu/24.04/amd64/ubuntu-installer/amd64/linux
    APPEND initrd=ubuntu/24.04/amd64/ubuntu-installer/amd64/initrd.gz text

LABEL ubuntu-rescue
    MENU LABEL Ubuntu 24.04 Rescue Mode
    KERNEL ubuntu/24.04/amd64/ubuntu-installer/amd64/linux
    APPEND initrd=ubuntu/24.04/amd64/ubuntu-installer/amd64/initrd.gz rescue/enable=true
EOF
}

start_services() {
    log_info "Starting and enabling TFTP service..."
    
    systemctl enable tftpd-hpa
    systemctl restart tftpd-hpa
    
    # Check service status
    if systemctl is-active --quiet tftpd-hpa; then
        log_info "TFTP service is running successfully"
    else
        log_error "Failed to start TFTP service"
        systemctl status tftpd-hpa
        exit 1
    fi
}

verify_setup() {
    log_info "Verifying PXE setup..."
    
    # Check if TFTP port is listening
    if netstat -tuln | grep -q ":69 "; then
        log_info "TFTP server is listening on port 69"
    else
        log_warn "TFTP server may not be listening on port 69"
    fi
    
    # Check file permissions
    local test_file="${TFTP_ROOT}/ubuntu/${UBUNTU_VERSION}/amd64/ubuntu-installer/amd64/linux"
    if [ -f "$test_file" ]; then
        log_info "Ubuntu kernel file found: $test_file"
    else
        log_warn "Ubuntu kernel file not found: $test_file"
    fi
    
    # Display summary
    echo ""
    log_info "PXE Boot Server Setup Complete!"
    echo "----------------------------------------"
    echo "TFTP Server IP: ${PXE_SERVER_IP}"
    echo "TFTP Root: ${TFTP_ROOT}"
    echo "Ubuntu Version: ${UBUNTU_VERSION}"
    echo "Architecture: AMD64 UEFI"
    echo ""
    log_info "Configure your DHCP server to point to ${PXE_SERVER_IP} for PXE boot"
    echo "For UEFI clients, set boot filename to: bootnetx64.efi"
}

main() {
    log_info "Starting PXE Boot Server setup..."
    log_info "Server IP: ${PXE_SERVER_IP}"
    log_info "Target: Ubuntu ${UBUNTU_VERSION} AMD64 UEFI"
    
    check_root
    install_packages
    setup_tftp_directories
    configure_tftp_server
    download_ubuntu_netboot
    setup_grub_config
    setup_pxelinux_config
    start_services
    verify_setup
    
    log_info "PXE Boot Server setup completed successfully!"
}

# Run main function
main "$@"
