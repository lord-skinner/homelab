#!/bin/bash

#########
# Root Filesystem Preparation Script for Network Boot
# 
# This script helps prepare root filesystems for network-booted nodes
# in a mixed architecture (ARM and AMD) Kubernetes cluster.
#
# Usage: 
# ./prepare-rootfs.sh <architecture> <node_name> [base_image_url]
# 
# Example:
# For ARM node
# sudo ./2_prepare-rootfs.sh arm worker1 https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-arm64.tar.xz
# For AMD node
# sudo ./2_prepare-rootfs.sh amd master1 https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-amd64.tar.xz
#########

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
NFS_DIR="${NETBOOT_DIR}/nfs"

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

# Check for correct number of arguments
if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <architecture> <node_name> [base_image_url]"
  echo "  architecture: arm or amd"
  echo "  node_name: Name of the node (e.g., worker1)"
  echo "  base_image_url: Optional URL to a rootfs tarball"
  exit 1
fi

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  log "error" "This script must be run as root."
  exit 1
fi

ARCHITECTURE=$1
NODE_NAME=$2
BASE_IMAGE_URL=$3

# Validate architecture
if [[ ! "$ARCHITECTURE" =~ ^(arm|amd)$ ]]; then
  log "error" "Architecture must be either 'arm' or 'amd'"
  exit 1
fi

# Set appropriate Debian architecture string
if [ "$ARCHITECTURE" == "arm" ]; then
  DEB_ARCH="arm64"
else
  DEB_ARCH="amd64"
fi

# Create directories
NODE_ROOT="${NFS_DIR}/${ARCHITECTURE}/${NODE_NAME}"
log "info" "Creating directory: ${NODE_ROOT}"
mkdir -p "${NODE_ROOT}"

# If base image URL is provided, download and extract it
if [ -n "$BASE_IMAGE_URL" ]; then
  log "info" "Downloading root filesystem from: ${BASE_IMAGE_URL}"
  wget -O /tmp/rootfs.tar.gz "$BASE_IMAGE_URL"
  
  log "info" "Extracting root filesystem to: ${NODE_ROOT}"
  tar -xzf /tmp/rootfs.tar.gz -C "${NODE_ROOT}"
  rm /tmp/rootfs.tar.gz
  
  log "success" "Root filesystem extracted successfully."
else
  # Check if debootstrap is installed
  if ! command -v debootstrap &> /dev/null; then
    log "info" "Installing debootstrap..."
    apt-get update && apt-get install -y debootstrap
  fi
  
  # Use debootstrap to create a minimal Debian system
  log "info" "Creating minimal Debian system using debootstrap..."
  log "info" "This may take several minutes..."
  debootstrap --arch="$DEB_ARCH" bullseye "$NODE_ROOT" http://deb.debian.org/debian
  
  log "success" "Base system created successfully."
fi

# Configure fstab for network boot
log "info" "Configuring fstab for network boot..."
cat > "${NODE_ROOT}/etc/fstab" << EOF
# Network boot fstab
proc            /proc           proc    defaults          0       0
sysfs           /sys            sysfs   defaults          0       0
tmpfs           /tmp            tmpfs   defaults          0       0
tmpfs           /var/log        tmpfs   defaults          0       0
EOF

# Create basic network configuration
log "info" "Configuring network settings..."
cat > "${NODE_ROOT}/etc/network/interfaces" << EOF
# The loopback network interface
auto lo
iface lo inet loopback

# The primary network interface
auto eth0
iface eth0 inet dhcp
EOF

# Configure hostname
log "info" "Setting hostname to: ${NODE_NAME}"
echo "$NODE_NAME" > "${NODE_ROOT}/etc/hostname"
cat > "${NODE_ROOT}/etc/hosts" << EOF
127.0.0.1       localhost
127.0.1.1       ${NODE_NAME}

# The following lines are desirable for IPv6 capable hosts
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

# Configure SSH for remote access
log "info" "Configuring SSH for remote access..."
if [ ! -d "${NODE_ROOT}/etc/ssh" ]; then
  mkdir -p "${NODE_ROOT}/etc/ssh"
fi

# Create a script to be run on first boot to generate SSH keys
cat > "${NODE_ROOT}/etc/rc.local" << 'EOF'
#!/bin/sh -e
# Generate SSH host keys on first boot if they don't exist
if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
  dpkg-reconfigure openssh-server
fi
exit 0
EOF
chmod +x "${NODE_ROOT}/etc/rc.local"

# Create a minimal required chroot setup script for installing additional packages
cat > "/tmp/chroot_setup.sh" << 'EOF'
#!/bin/bash
set -e

# Update package lists
apt-get update

# Install essential packages
apt-get install -y --no-install-recommends \
  linux-image-generic \
  openssh-server \
  sudo \
  ca-certificates \
  curl \
  less \
  vim \
  systemd \
  systemd-sysv \
  locales \
  net-tools \
  iproute2 \
  iputils-ping

# Generate locales
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen

# Configure timezone
ln -sf /usr/share/zoneinfo/UTC /etc/localtime

# Create a user with sudo access
useradd -m -s /bin/bash k8s
echo "k8s:k8s" | chpasswd
usermod -aG sudo k8s

# Allow password-less sudo for the k8s user
echo "k8s ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/k8s

# Clean up
apt-get clean
rm -rf /var/lib/apt/lists/*
EOF
chmod +x "/tmp/chroot_setup.sh"

# Copy the setup script to the chroot and execute it
cp "/tmp/chroot_setup.sh" "${NODE_ROOT}/tmp/"
log "info" "Setting up packages inside the chroot environment..."
log "info" "This will take some time..."

# Mount required filesystems for chroot
mount -t proc none "${NODE_ROOT}/proc"
mount -t sysfs none "${NODE_ROOT}/sys"
mount -o bind /dev "${NODE_ROOT}/dev"
mount -o bind /dev/pts "${NODE_ROOT}/dev/pts"

# Execute the setup script in the chroot
chroot "${NODE_ROOT}" /bin/bash /tmp/chroot_setup.sh

# Unmount filesystems
umount "${NODE_ROOT}/dev/pts"
umount "${NODE_ROOT}/dev"
umount "${NODE_ROOT}/sys"
umount "${NODE_ROOT}/proc"

# Clean up
rm "/tmp/chroot_setup.sh"
rm "${NODE_ROOT}/tmp/chroot_setup.sh"

# Set permissions
log "info" "Setting permissions..."
chmod -R 755 "${NODE_ROOT}"

# Configure Kubernetes prerequisites
log "info" "Configuring Kubernetes prerequisites..."
cat > "${NODE_ROOT}/etc/modules-load.d/k8s.conf" << EOF
overlay
br_netfilter
EOF

cat > "${NODE_ROOT}/etc/sysctl.d/k8s.conf" << EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

# Final instructions
log "success" "Root filesystem for ${NODE_NAME} (${ARCHITECTURE}) prepared successfully!"
log "info" "Root filesystem location: ${NODE_ROOT}"
log "info" "Next steps:"
log "info" "1. Ensure you have the appropriate kernel (vmlinuz) and initrd in the TFTP directory"
log "info" "2. Add the node to the DHCP configuration using the add-node.sh script"
log "info" "3. Update the NFS exports if needed"
log "info" "4. Configure your node to boot from the network"

exit 0
