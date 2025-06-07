#!/bin/bash
#
# Network Boot Server Setup Script for Raspberry Pi 3
# 
# This script configures a Raspberry Pi 3 to serve as a network boot server
# for a mixed architecture (ARM and AMD) Kubernetes cluster.
#
# Services configured:
# - DHCP server (dnsmasq)
# - TFTP server (dnsmasq)
# - NFS server (for root filesystems)
#
# Usage: ./setup-netboot.sh
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

# Directory structure
NETBOOT_DIR="/srv/netboot"
TFTP_DIR="${NETBOOT_DIR}/tftp"
NFS_DIR="${NETBOOT_DIR}/nfs"
ARM_DIR="${NFS_DIR}/arm"
AMD_DIR="${NFS_DIR}/amd"

# Network configuration - MODIFY THESE VALUES TO MATCH YOUR NETWORK
NETWORK_INTERFACE="eth0"
NETWORK_SUBNET="192.168.1.0"
NETWORK_MASK="255.255.255.0"
DHCP_RANGE_START="192.168.1.100"
DHCP_RANGE_END="192.168.1.200"
SERVER_IP="192.168.1.10"  # Pi's IP address

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

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  log "error" "This script must be run as root."
  exit 1
fi

# Check for Raspberry Pi model
if ! grep -q "Raspberry Pi 3" /proc/device-tree/model 2>/dev/null; then
  log "warn" "This script is designed for Raspberry Pi 3. You appear to be running on a different device."
  read -p "Continue anyway? (y/n): " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
  fi
fi

# Update system
log "info" "Updating system packages..."
apt-get update && apt-get upgrade -y

# Install required packages
log "info" "Installing required packages..."
apt-get install -y dnsmasq nfs-kernel-server pxelinux syslinux-common isc-dhcp-server

# Create necessary directories
log "info" "Creating directory structure..."
mkdir -p ${TFTP_DIR}/{pxelinux.cfg,arm,amd}
mkdir -p ${ARM_DIR}
mkdir -p ${AMD_DIR}

# Configure static IP for the Raspberry Pi
log "info" "Configuring static IP address..."
cat > /etc/dhcpcd.conf << EOF
interface ${NETWORK_INTERFACE}
static ip_address=${SERVER_IP}/24
static routers=192.168.1.1
static domain_name_servers=1.1.1.1 8.8.8.8
EOF

# Configure DHCP server
log "info" "Configuring DHCP server..."
cat > /etc/dhcp/dhcpd.conf << EOF
option domain-name "homelab.local";
option domain-name-servers 1.1.1.1, 8.8.8.8;
default-lease-time 600;
max-lease-time 7200;
ddns-update-style none;
authoritative;

subnet ${NETWORK_SUBNET} netmask ${NETWORK_MASK} {
  range ${DHCP_RANGE_START} ${DHCP_RANGE_END};
  option subnet-mask ${NETWORK_MASK};
  option routers 192.168.1.1;
  option broadcast-address 192.168.1.255;
  
  # AMD64 clients
  class "amd64-clients" {
    match if substring (option vendor-class-identifier, 0, 5) = "amd64";
    filename "amd/grub2/grubx64.efi";
  }
  
  # ARM clients
  class "arm64-clients" {
    match if substring (option vendor-class-identifier, 0, 5) = "arm64";
    filename "arm/u-boot.bin";
  }
  
  # Legacy BIOS clients
  class "legacy-clients" {
    match if substring (option vendor-class-identifier, 0, 5) = "legacy";
    filename "pxelinux.0";
  }
}

# Fixed IP address assignments for cluster nodes
# Uncomment and modify these as needed for your cluster nodes
# host node1 {
#   hardware ethernet 00:11:22:33:44:55;
#   fixed-address 192.168.1.101;
#   option host-name "node1";
# }
# host node2 {
#   hardware ethernet 00:11:22:33:44:66;
#   fixed-address 192.168.1.102;
#   option host-name "node2";
# }
EOF

# Configure the ISC DHCP server interface
cat > /etc/default/isc-dhcp-server << EOF
INTERFACESv4="${NETWORK_INTERFACE}"
INTERFACESv6=""
EOF

# Configure TFTP server (dnsmasq)
log "info" "Configuring TFTP server..."
cat > /etc/dnsmasq.conf << EOF
# DHCP settings
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},12h
dhcp-option=3,192.168.1.1  # Default gateway
dhcp-option=6,1.1.1.1,8.8.8.8  # DNS servers

# PXE boot settings
enable-tftp
tftp-root=${TFTP_DIR}

# Boot file configurations
# For UEFI AMD64 systems
dhcp-match=set:efi-x86_64,option:client-arch,7
dhcp-boot=tag:efi-x86_64,amd/grub2/grubx64.efi

# For ARM64 systems
dhcp-match=set:efi-arm64,option:client-arch,11
dhcp-boot=tag:efi-arm64,arm/u-boot.bin

# For legacy BIOS
dhcp-match=set:bios,option:client-arch,0
dhcp-boot=tag:bios,pxelinux.0

# Log settings
log-dhcp
log-queries
EOF

# Configure NFS server
log "info" "Configuring NFS server..."
cat > /etc/exports << EOF
${ARM_DIR} *(rw,sync,no_subtree_check,no_root_squash)
${AMD_DIR} *(rw,sync,no_subtree_check,no_root_squash)
EOF

# Set up PXE boot files for legacy BIOS
log "info" "Setting up PXE boot files..."
cp /usr/lib/PXELINUX/pxelinux.0 ${TFTP_DIR}/
cp /usr/lib/syslinux/modules/bios/*.c32 ${TFTP_DIR}/
mkdir -p ${TFTP_DIR}/pxelinux.cfg

# Create default PXE configuration for legacy BIOS
cat > ${TFTP_DIR}/pxelinux.cfg/default << EOF
DEFAULT menu.c32
PROMPT 0
TIMEOUT 300
ONTIMEOUT local

MENU TITLE PXE Boot Menu

LABEL local
    MENU LABEL Boot from local disk
    LOCALBOOT 0

LABEL amd64_node
    MENU LABEL Boot AMD64 Node
    KERNEL amd/vmlinuz
    APPEND initrd=amd/initrd.img root=/dev/nfs nfsroot=${SERVER_IP}:${AMD_DIR} ip=dhcp rw

LABEL arm64_node
    MENU LABEL Boot ARM64 Node
    KERNEL arm/vmlinuz
    APPEND initrd=arm/initrd.img root=/dev/nfs nfsroot=${SERVER_IP}:${ARM_DIR} ip=dhcp rw
EOF

# Setup UEFI PXE for AMD64
mkdir -p ${TFTP_DIR}/amd/grub2
# Note: You'll need to obtain UEFI GRUB files for AMD64 and place them here

# Setup UEFI PXE for ARM64
mkdir -p ${TFTP_DIR}/arm
# Note: You'll need to obtain U-Boot for ARM64 and place it here

# Create simple README files with instructions for adding boot files
cat > ${TFTP_DIR}/amd/README.txt << EOF
Place AMD64 boot files here:
- vmlinuz: The Linux kernel
- initrd.img: Initial RAM disk
- For UEFI boot: Place GRUB EFI files in the grub2/ directory
EOF

cat > ${TFTP_DIR}/arm/README.txt << EOF
Place ARM64 boot files here:
- vmlinuz: The Linux kernel
- initrd.img: Initial RAM disk
- u-boot.bin: U-Boot binary for ARM64 systems
EOF

# Set permissions
log "info" "Setting permissions..."
chmod -R 777 ${NETBOOT_DIR}
chown -R nobody:nogroup ${NETBOOT_DIR}

# Enable and start services
log "info" "Enabling and starting services..."
systemctl enable rpcbind
systemctl enable nfs-kernel-server
systemctl restart rpcbind
systemctl restart nfs-kernel-server
exportfs -a

systemctl enable dnsmasq
systemctl restart dnsmasq

systemctl enable isc-dhcp-server
systemctl restart isc-dhcp-server

# Create helper scripts for adding new nodes
cat > ${NETBOOT_DIR}/add-node.sh << 'EOF'
#!/bin/bash

# Helper script to add a new node to the network boot configuration

if [ "$#" -ne 4 ]; then
    echo "Usage: $0 <node_name> <mac_address> <ip_address> <architecture>"
    echo "  architecture: arm or amd"
    exit 1
fi

NODE_NAME=$1
MAC_ADDRESS=$2
IP_ADDRESS=$3
ARCHITECTURE=$4

if [[ ! "$ARCHITECTURE" =~ ^(arm|amd)$ ]]; then
    echo "Error: Architecture must be either 'arm' or 'amd'"
    exit 1
fi

# Add to DHCP configuration
echo "
host $NODE_NAME {
  hardware ethernet $MAC_ADDRESS;
  fixed-address $IP_ADDRESS;
  option host-name \"$NODE_NAME\";
}" >> /etc/dhcp/dhcpd.conf

# Reload DHCP server
systemctl restart isc-dhcp-server

# Create directory for node's root filesystem
mkdir -p /srv/netboot/nfs/$ARCHITECTURE/$NODE_NAME

echo "Node $NODE_NAME added successfully with IP $IP_ADDRESS and architecture $ARCHITECTURE"
echo "Next steps:"
echo "1. Prepare the root filesystem in /srv/netboot/nfs/$ARCHITECTURE/$NODE_NAME"
echo "2. Modify NFS exports if needed"
echo "3. Restart the NFS server with: systemctl restart nfs-kernel-server"
echo "4. Ensure boot files for $ARCHITECTURE are available in /srv/netboot/tftp/$ARCHITECTURE/"
EOF

chmod +x ${NETBOOT_DIR}/add-node.sh

# Final instructions
log "success" "Network boot server setup complete!"
log "info" "Next steps:"
log "info" "1. Add boot files for your specific systems:"
log "info" "   - For AMD64: Place vmlinuz and initrd.img in ${TFTP_DIR}/amd/"
log "info" "   - For ARM64: Place vmlinuz, initrd.img and u-boot.bin in ${TFTP_DIR}/arm/"
log "info" "2. Prepare root filesystems for your nodes in ${NFS_DIR}/{arm,amd}/"
log "info" "3. Use the helper script to add nodes: ${NETBOOT_DIR}/add-node.sh"
log "info" "4. Modify network configuration in the script if needed"
log "info" "5. Test booting your cluster nodes"

# Print summary
log "info" "Server IP: ${SERVER_IP}"
log "info" "TFTP Directory: ${TFTP_DIR}"
log "info" "NFS Directory: ${NFS_DIR}"
log "info" "DHCP Range: ${DHCP_RANGE_START} - ${DHCP_RANGE_END}"

exit 0
