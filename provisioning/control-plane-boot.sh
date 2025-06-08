#!/bin/bash
# Sets up a DHCP and TFTP server for network booting with PXE

set -euo pipefail

# Variables
TFTP_ROOT="/srv/tftp"
PXE_ROOT="/srv/tftp/pxelinux"
DEBIAN_IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
DEBIAN_IMAGE_NAME="debian-12-generic-amd64.qcow2"
NETBOOT_URL="http://ftp.debian.org/debian/dists/bookworm/main/installer-amd64/current/images/netboot/netboot.tar.gz"

# Network configuration - adjust these for your network
DHCP_SUBNET="10.0.0.1"
DHCP_NETMASK="255.255.255.0"
DHCP_RANGE_START="10.0.0.200"
DHCP_RANGE_END="10.0.0.209"
DHCP_ROUTER="10.0.0.1"
DHCP_DNS="8.8.8.8, 8.8.4.4"
SERVER_IP="10.0.0.10"

# Install required packages
sudo apt-get update
sudo apt-get install -y tftpd-hpa isc-dhcp-server wget

# Create TFTP root directory if it doesn't exist
sudo mkdir -p "$TFTP_ROOT"
sudo mkdir -p "$PXE_ROOT"
sudo chown -R tftp:tftp "$TFTP_ROOT"

# Download and extract PXE boot files
if [ ! -f "$TFTP_ROOT/pxelinux.0" ]; then
    echo "Downloading PXE boot files..."
    cd /tmp
    wget "$NETBOOT_URL"
    sudo tar -xzf netboot.tar.gz -C "$TFTP_ROOT"
    sudo chown -R tftp:tftp "$TFTP_ROOT"
fi

# Download Debian cloud image if not already present
if [ ! -f "$TFTP_ROOT/$DEBIAN_IMAGE_NAME" ]; then
    echo "Downloading Debian cloud image..."
    sudo wget -O "$TFTP_ROOT/$DEBIAN_IMAGE_NAME" "$DEBIAN_IMAGE_URL"
    sudo chown tftp:tftp "$TFTP_ROOT/$DEBIAN_IMAGE_NAME"
fi

# Configure tftpd-hpa
sudo tee /etc/default/tftpd-hpa > /dev/null <<EOF
TFTP_USERNAME="tftp"
TFTP_DIRECTORY="$TFTP_ROOT"
TFTP_ADDRESS="0.0.0.0:69"
TFTP_OPTIONS="--secure"
EOF

# Configure DHCP server
sudo tee /etc/dhcp/dhcpd.conf > /dev/null <<EOF
# DHCP configuration for PXE booting
default-lease-time 600;
max-lease-time 7200;
authoritative;

# PXE boot configuration
allow booting;
allow bootp;

# Subnet configuration
subnet $DHCP_SUBNET netmask $DHCP_NETMASK {
    range $DHCP_RANGE_START $DHCP_RANGE_END;
    option domain-name-servers $DHCP_DNS;
    option routers $DHCP_ROUTER;
    option broadcast-address $(echo $DHCP_SUBNET | sed 's/\.0$/.255/');
    
    # PXE boot options
    next-server $SERVER_IP;
    filename "pxelinux.0";
    
    # Boot options for different architectures
    if substring (option vendor-class-identifier, 0, 9) = "PXEClient" {
        filename "pxelinux.0";
    }
}
EOF

# Set the network interface for DHCP server
INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
sudo tee /etc/default/isc-dhcp-server > /dev/null <<EOF
# Defaults for isc-dhcp-server
DHCPDv4_CONF=/etc/dhcp/dhcpd.conf
DHCPDv4_PID=/var/run/dhcpd.pid
INTERFACESv4="$INTERFACE"
EOF

# Restart services
sudo systemctl restart tftpd-hpa
sudo systemctl enable tftpd-hpa
sudo systemctl restart isc-dhcp-server
sudo systemctl enable isc-dhcp-server

echo "DHCP and TFTP servers are set up for network booting"
echo "DHCP server serving range: $DHCP_RANGE_START - $DHCP_RANGE_END"
echo "TFTP server serving from: $TFTP_ROOT"
echo "Next server (TFTP): $SERVER_IP"
echo ""
echo "Configure your network equipment to use this server ($SERVER_IP) as DHCP server"
echo "or set DHCP option 66 (TFTP server) to $SERVER_IP and option 67 (boot filename) to 'pxelinux.0'"