#!/bin/bash
# Sets up TFTP and HTTP servers for network booting with PXE for stateless machines
# DHCP is handled by network router with PXE options configured

set -euo pipefail

# Variables
TFTP_ROOT="/srv/tftp"
PXE_ROOT="/srv/tftp/pxelinux"
HTTP_ROOT="/srv/http"
MACHINE_CONFIGS_ROOT="/srv/http/machines"
STATE_ROOT="/srv/state"
LIVE_ROOT="/srv/http/live"
MACHINE_STATE_ROOT="/srv/http/machine-state"
NETBOOT_URL="http://ftp.debian.org/debian/dists/bookworm/main/installer-amd64/current/images/netboot/netboot.tar.gz"
DEBIAN_LIVE_URL="https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/debian-live-12.8.0-amd64-standard.iso"
DEBIAN_LIVE_ISO="debian-live-12.8.0-amd64-standard.iso"
KERNEL_PATH="live/vmlinuz"
INITRD_PATH="live/initrd.img"

# Network configuration
SERVER_IP="10.0.0.2"

# Install required packages
sudo apt-get update
sudo apt-get install -y tftpd-hpa nginx wget jq cloud-init

# Create TFTP root directory if it doesn't exist
sudo mkdir -p "$TFTP_ROOT"
sudo mkdir -p "$PXE_ROOT"
sudo mkdir -p "$HTTP_ROOT"
sudo mkdir -p "$MACHINE_CONFIGS_ROOT"
sudo mkdir -p "$STATE_ROOT"
sudo mkdir -p "$HTTP_ROOT/preseed"
sudo mkdir -p "$HTTP_ROOT/cloud-init"
sudo mkdir -p "$HTTP_ROOT/scripts"
sudo mkdir -p "$LIVE_ROOT"
sudo mkdir -p "$MACHINE_STATE_ROOT"
sudo chown -R tftp:tftp "$TFTP_ROOT"
sudo chown -R www-data:www-data "$HTTP_ROOT"
sudo chown -R root:root "$STATE_ROOT"

# Download and extract PXE boot files
if [ ! -f "$TFTP_ROOT/pxelinux.0" ]; then
    echo "Downloading PXE boot files..."
    cd /tmp
    wget "$NETBOOT_URL"
    sudo tar -xzf netboot.tar.gz -C "$TFTP_ROOT"
    sudo chown -R tftp:tftp "$TFTP_ROOT"
fi

# Set up UEFI boot files in the correct locations
echo "Setting up UEFI boot files..."
sudo cp -f "$TFTP_ROOT/debian-installer/amd64/bootnetx64.efi" "$TFTP_ROOT/" 2>/dev/null || true
sudo cp -f "$TFTP_ROOT/debian-installer/amd64/grubx64.efi" "$TFTP_ROOT/" 2>/dev/null || true

# Remove any existing empty revocations.efi file that might cause boot issues
sudo rm -f "$TFTP_ROOT/revocations.efi"

# Copy GRUB configuration and modules to TFTP root
sudo mkdir -p "$TFTP_ROOT/grub"
sudo cp -rf "$TFTP_ROOT/debian-installer/amd64/grub/"* "$TFTP_ROOT/grub/" 2>/dev/null || true

# Ensure proper ownership
sudo chown -R tftp:tftp "$TFTP_ROOT"

# Download Alpine Linux for true stateless booting
echo "Setting up Alpine Linux for stateless operation..."
ALPINE_VERSION="3.18"
ALPINE_ARCH="x86_64"
ALPINE_ISO_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/${ALPINE_ARCH}/alpine-netboot-${ALPINE_VERSION}.0-${ALPINE_ARCH}.tar.gz"
ALPINE_AVAILABLE=false

if [ ! -f "$LIVE_ROOT/alpine-netboot.tar.gz" ]; then
    echo "Downloading Alpine Linux netboot files..."
    sudo mkdir -p "$LIVE_ROOT"
    cd "$LIVE_ROOT"
    
    # Download Alpine netboot with timeout
    timeout 60 sudo wget -O "alpine-netboot.tar.gz" "$ALPINE_ISO_URL" || {
        echo "Alpine download failed - falling back to Debian installer"
        sudo rm -f "alpine-netboot.tar.gz"
    }
fi

# Extract Alpine files if download was successful
if [ -f "$LIVE_ROOT/alpine-netboot.tar.gz" ] && [ -s "$LIVE_ROOT/alpine-netboot.tar.gz" ]; then
    echo "Extracting Alpine netboot files..."
    cd "$LIVE_ROOT"
    sudo tar -xzf alpine-netboot.tar.gz
    
    # Copy Alpine boot files to TFTP root
    sudo mkdir -p "$TFTP_ROOT/alpine"
    if [ -f "boot/vmlinuz-lts" ] && [ -f "boot/initramfs-lts" ]; then
        sudo cp boot/vmlinuz-lts "$TFTP_ROOT/alpine/"
        sudo cp boot/initramfs-lts "$TFTP_ROOT/alpine/"
        
        # Also copy modloop to HTTP root for download
        sudo mkdir -p "$HTTP_ROOT/alpine/boot"
        [ -f "boot/modloop-lts" ] && sudo cp boot/modloop-lts "$HTTP_ROOT/alpine/boot/"
        
        sudo chown -R tftp:tftp "$TFTP_ROOT/alpine"
        sudo chown -R www-data:www-data "$HTTP_ROOT/alpine"
        
        # Create Alpine overlay (apkovl) for stateless provisioning
        echo "Creating Alpine overlay for stateless provisioning..."
        sudo mkdir -p "$HTTP_ROOT/alpine/apkovl"
        
        # Create a minimal overlay structure
        OVERLAY_DIR="/tmp/alpine-overlay"
        sudo rm -rf "$OVERLAY_DIR"
        sudo mkdir -p "$OVERLAY_DIR/etc/local.d"
        sudo mkdir -p "$OVERLAY_DIR/etc/runlevels/default"
        
        # Create the provisioning script that runs on boot
        sudo tee "$OVERLAY_DIR/etc/local.d/kubernetes-provision.start" > /dev/null <<'PROVISION_EOF'
#!/bin/ash
# Kubernetes provisioning script for Alpine Linux stateless machines

# Wait for network
sleep 5

# Get MAC address
MAC_ADDRESS=$(cat /sys/class/net/eth*/address | head -1 | tr '[:upper:]' '[:lower:]')

# Download and run the main provisioning script
wget -qO /tmp/provision.sh "http://10.0.0.2/scripts/alpine-provision.sh"
chmod +x /tmp/provision.sh
/tmp/provision.sh "$MAC_ADDRESS" || echo "Provisioning failed, continuing..."

# Mark as executable
chmod +x /etc/local.d/kubernetes-provision.start
PROVISION_EOF

        sudo chmod +x "$OVERLAY_DIR/etc/local.d/kubernetes-provision.start"
        
        # Enable local service
        sudo ln -sf /etc/init.d/local "$OVERLAY_DIR/etc/runlevels/default/local"
        
        # Create the overlay tarball
        cd "$OVERLAY_DIR"
        sudo tar -czf "$HTTP_ROOT/alpine/apkovl/kubernetes.apkovl.tar.gz" .
        sudo chown www-data:www-data "$HTTP_ROOT/alpine/apkovl/kubernetes.apkovl.tar.gz"
        
        # Clean up
        sudo rm -rf "$OVERLAY_DIR"
        
        ALPINE_AVAILABLE=true
        echo "Alpine Linux files and overlay ready for stateless boot"
    else
        echo "Alpine extraction failed - using Debian installer"
        ALPINE_AVAILABLE=false
    fi
else
    echo "Alpine not available - using Debian installer"
    ALPINE_AVAILABLE=false
fi

# Create Alpine-specific provisioning script
sudo tee "$HTTP_ROOT/scripts/alpine-provision.sh" > /dev/null <<'ALPINE_EOF'
#!/bin/ash
# Alpine Linux provisioning script for stateless machines

set -euo pipefail

MAC_ADDRESS="$1"

# Basic Alpine setup
apk update
apk add curl wget jq bash docker containerd openssh-server sudo

# Enable services
rc-update add docker default
rc-update add containerd default
rc-update add sshd default

# Get configuration from machine registry
CONFIG=$(wget -qO- "http://10.0.0.2/machines/registry.json" || echo '{}')
MACHINE_INFO=$(echo "$CONFIG" | jq -r ".machines[\"$MAC_ADDRESS\"] // empty")

if [ -n "$MACHINE_INFO" ] && [ "$MACHINE_INFO" != "null" ]; then
    HOSTNAME=$(echo "$MACHINE_INFO" | jq -r '.hostname // "alpine-stateless"')
    ROLE=$(echo "$MACHINE_INFO" | jq -r '.role // "worker"')
    FEATURES=$(echo "$MACHINE_INFO" | jq -r '.features[]? // empty' | tr '\n' ' ')
    
    echo "Machine found in registry: $HOSTNAME (Role: $ROLE, Features: $FEATURES)"
else
    HOSTNAME="alpine-$MAC_ADDRESS"
    ROLE="worker"
    FEATURES=""
    echo "Machine not found in registry, using defaults"
fi

# Set hostname
hostname "$HOSTNAME"
echo "$HOSTNAME" > /etc/hostname

# Configure networking
cat > /etc/network/interfaces <<NETEOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
NETEOF

# Create admin user
adduser -D admin
echo "admin:kubernetes123" | chpasswd
addgroup admin wheel
echo '%wheel ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers

# Install SSH keys if available
mkdir -p /home/admin/.ssh
wget -qO /home/admin/.ssh/authorized_keys "http://10.0.0.2/cloud-init/$MAC_ADDRESS/authorized_keys" || true
chown -R admin:admin /home/admin/.ssh
chmod 700 /home/admin/.ssh
chmod 600 /home/admin/.ssh/authorized_keys 2>/dev/null || true

# Start SSH service
service sshd start

# Handle kubernetes feature installation
if echo "$FEATURES" | grep -q "kubernetes"; then
    echo "Installing kubernetes feature..."
    
    # Install Kubernetes tools
    apk add kubelet kubeadm kubectl --repository=http://dl-cdn.alpinelinux.org/alpine/edge/testing
    
    # Create kubelet service
    rc-update add kubelet default
    
    # Download kubernetes-specific configurations
    mkdir -p /etc/kubernetes
    wget -qO /etc/kubernetes/config.yaml "http://10.0.0.2/scripts/kubernetes-config.yaml" || true
    
    echo "Kubernetes feature installed"
fi

# Report successful provisioning
wget -qO- --post-data="{\"mac\":\"$MAC_ADDRESS\",\"hostname\":\"$HOSTNAME\",\"state\":\"provisioned\",\"message\":\"Alpine stateless boot with kubernetes complete\",\"timestamp\":\"$(date -Iseconds)\"}" \
    --header="Content-Type: application/json" \
    "http://10.0.0.2/api/state" || echo "Could not report state"

echo "Alpine stateless provisioning complete for $HOSTNAME"
ALPINE_EOF

sudo chmod +x "$HTTP_ROOT/scripts/alpine-provision.sh"

# Create cloud-init configuration generator script
sudo tee "$HTTP_ROOT/scripts/generate-cloud-init.sh" > /dev/null <<'EOF'
#!/bin/bash
# Generates cloud-init configuration for stateless machines

set -euo pipefail

MAC_ADDRESS="$1"
OUTPUT_DIR="$2"
REGISTRY_FILE="$3"
SERVER_IP="$4"

# Get machine info from registry
MACHINE_INFO=$(jq -r ".machines[\"$MAC_ADDRESS\"] // empty" "$REGISTRY_FILE")

if [ -z "$MACHINE_INFO" ]; then
    echo "Machine $MAC_ADDRESS not found in registry"
    exit 1
fi

HOSTNAME=$(echo "$MACHINE_INFO" | jq -r '.hostname')
ROLE=$(echo "$MACHINE_INFO" | jq -r '.role')
IP=$(echo "$MACHINE_INFO" | jq -r '.ip')
FEATURES=$(echo "$MACHINE_INFO" | jq -r '.features | join(",")')

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Generate meta-data
cat > "$OUTPUT_DIR/meta-data" <<METAEND
instance-id: $HOSTNAME
local-hostname: $HOSTNAME
METAEND

# Generate network-config
cat > "$OUTPUT_DIR/network-config" <<NETEND
version: 2
ethernets:
  eth0:
    match:
      macaddress: $MAC_ADDRESS
    addresses:
      - $IP/24
    gateway4: 10.0.0.1
    nameservers:
      addresses: [8.8.8.8, 8.8.4.4]
NETEND

# Generate user-data
cat > "$OUTPUT_DIR/user-data" <<USEREND
#cloud-config

hostname: $HOSTNAME
fqdn: $HOSTNAME.local

# Create default user
users:
  - name: admin
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: changeme
    
# Configure ssh access
ssh_pwauth: true
ssh_authorized_keys:
  - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC0WGP1EZykEtv5YGC9nMiRWiST9g+xYbTMRxXhSKxM2Hm5UbE4J1cZxmm6rNDIxTnzTzCcmV1enV1O+GJgXBKEXbMyv9X1S3V5QmyPCBmzuJHTtHQJNA5MzLbI3IIQ5VV7hXJk1oGJpN9xwFMjB4ZDJFwWYzXUeUlGvJXM0xpxgCwVd/YYZYkWJFUGwjY+qfSI4UPoaQFuzW80m4fqQmrW1kEoUm/iKuGDoHUfLwRKOgFDxgRjJXJVyGxIH/TWmTMWvL0+GjHEJlAYRZ1+BDgxsCYbVmJ3lgVw84BZQK3OzeRCQwiOYPAFEfTixwrEn8b9azE+2ry1BHUB8oQr/dLZ admin@server

# Install necessary packages
packages:
  - curl
  - wget
  - jq
  - docker.io
  - containerd

# Run commands after boot
runcmd:
  - wget -O /usr/local/bin/machine-state.sh http://$SERVER_IP/scripts/machine-state.sh
  - chmod +x /usr/local/bin/machine-state.sh
  - /usr/local/bin/machine-state.sh report "booted" "Machine booted successfully"
  - wget -O /tmp/provision-machine.sh http://$SERVER_IP/scripts/provision-machine.sh
  - chmod +x /tmp/provision-machine.sh
  - /tmp/provision-machine.sh
USEREND

echo "Generated cloud-init configuration for $HOSTNAME ($MAC_ADDRESS) in $OUTPUT_DIR"
EOF

# Make the generator script executable
sudo chmod +x "$HTTP_ROOT/scripts/generate-cloud-init.sh"

# Create stateless boot helper script
sudo tee "$HTTP_ROOT/scripts/stateless-boot-helper.sh" > /dev/null <<'EOF'
#!/bin/bash
# Helper script that runs in the stateless environment during boot

set -euo pipefail

# Determine MAC address
MAC_ADDRESS=$(cat /sys/class/net/*/address | grep -v "00:00:00:00:00:00" | head -1)
SERVER_IP="10.0.0.2"

# Report boot status
curl -X POST "http://$SERVER_IP/api/state" \
    -H "Content-Type: application/json" \
    -d "{
        \"mac\": \"$MAC_ADDRESS\",
        \"hostname\": \"$(hostname)\",
        \"state\": \"booting\",
        \"message\": \"Stateless system booting\",
        \"timestamp\": \"$(date -Iseconds)\"
    }"

# Download and run the provisioning script for additional setup
wget -O /tmp/provision-machine.sh "http://$SERVER_IP/scripts/provision-machine.sh"
chmod +x /tmp/provision-machine.sh
/tmp/provision-machine.sh
EOF

sudo chmod +x "$HTTP_ROOT/scripts/stateless-boot-helper.sh"

# Create machine registry and configurations
echo "Setting up machine registry and configurations..."

# Create machine registry
sudo tee "$MACHINE_CONFIGS_ROOT/registry.json" > /dev/null <<EOF
{
  "machines": {
    "a8:a1:59:41:29:0f": {
      "hostname": "cp-1",
      "role": "worker",
      "architecture": "amd64",
      "features": ["kubernetes", "nfs", "storage"],
      "ip": "10.0.0.20",
      "specs": {
        "cpu": "unknown",
        "memory": "unknown"
      }
    }
  },
  "defaults": {
    "timezone": "America/New_York",
    "ssh_keys": [],
    "packages": ["curl", "wget", "htop", "git", "docker.io", "containerd"]
  }
}
EOF

# Create machine state tracking script
sudo tee "$HTTP_ROOT/scripts/machine-state.sh" > /dev/null <<'EOF'
#!/bin/bash
# Machine state management script
set -euo pipefail

STATE_SERVER="http://10.0.0.2"
MAC_ADDRESS=$(cat /sys/class/net/*/address | grep -v "00:00:00:00:00:00" | head -1)
HOSTNAME=$(hostname)

# Function to report machine state
report_state() {
    local state="$1"
    local message="${2:-}"
    
    curl -X POST "$STATE_SERVER/api/state" \
        -H "Content-Type: application/json" \
        -d "{
            \"mac\": \"$MAC_ADDRESS\",
            \"hostname\": \"$HOSTNAME\",
            \"state\": \"$state\",
            \"message\": \"$message\",
            \"timestamp\": \"$(date -Iseconds)\"
        }" || true
}

# Function to get machine configuration
get_config() {
    curl -s "$STATE_SERVER/api/config/$MAC_ADDRESS" | jq -r '.'
}

# Function to save persistent data
save_data() {
    local key="$1"
    local value="$2"
    
    curl -X POST "$STATE_SERVER/api/data" \
        -H "Content-Type: application/json" \
        -d "{
            \"mac\": \"$MAC_ADDRESS\",
            \"key\": \"$key\",
            \"value\": \"$value\"
        }" || true
}

# Function to get persistent data
get_data() {
    local key="$1"
    curl -s "$STATE_SERVER/api/data/$MAC_ADDRESS/$key" | jq -r '.value'
}

case "${1:-}" in
    "report")
        report_state "$2" "$3"
        ;;
    "config")
        get_config
        ;;
    "save")
        save_data "$2" "$3"
        ;;
    "get")
        get_data "$2"
        ;;
    *)
        echo "Usage: $0 {report|config|save|get} [args...]"
        exit 1
        ;;
esac
EOF

# Create machine provisioning script
sudo tee "$HTTP_ROOT/scripts/provision-machine.sh" > /dev/null <<'EOF'
#!/bin/bash
# Machine-specific provisioning script
set -euo pipefail

STATE_SCRIPT="/tmp/machine-state.sh"
MAC_ADDRESS=$(cat /sys/class/net/*/address | grep -v "00:00:00:00:00:00" | head -1)

# Download state management script
wget -O "$STATE_SCRIPT" http://10.0.0.2/scripts/machine-state.sh
chmod +x "$STATE_SCRIPT"

# Report boot started
"$STATE_SCRIPT" report "provisioning" "Starting machine provisioning"

# Get machine configuration
CONFIG=$("$STATE_SCRIPT" config)
ROLE=$(echo "$CONFIG" | jq -r '.role')
FEATURES=$(echo "$CONFIG" | jq -r '.features[]')
HOSTNAME=$(echo "$CONFIG" | jq -r '.hostname')

echo "Provisioning machine: $HOSTNAME (Role: $ROLE)"

# Set hostname
hostnamectl set-hostname "$HOSTNAME"

# Install base packages
apt-get update
apt-get install -y $(echo "$CONFIG" | jq -r '.defaults.packages[]')

# Configure based on role and features
for feature in $FEATURES; do
    case "$feature" in
        "kubernetes")
            echo "Setting up Kubernetes..."
            # Add Kubernetes repository
            curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
            echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list
            apt-get update
            apt-get install -y kubelet kubeadm kubectl
            apt-mark hold kubelet kubeadm kubectl
            
            # Configure container runtime
            systemctl enable --now containerd
            ;;
        "gpu")
            echo "Setting up GPU support..."
            # Install NVIDIA drivers and container toolkit
            apt-get install -y nvidia-driver-535 nvidia-container-toolkit
            systemctl restart containerd
            ;;
        "nfs")
            echo "Setting up NFS server..."
            apt-get install -y nfs-kernel-server
            mkdir -p /srv/nfs/shared
            echo "/srv/nfs/shared *(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
            systemctl enable --now nfs-kernel-server
            ;;
        "storage")
            echo "Setting up storage..."
            # Configure additional storage based on machine specs
            ;;
    esac
done

# Role-specific configuration
case "$ROLE" in
    "control-plane")
        echo "Configuring as Kubernetes control plane..."
        # Save cluster configuration for later initialization
        "$STATE_SCRIPT" save "k8s-role" "control-plane"
        
        # Download and run device passthrough configuration
        wget -O /tmp/device-passthrough.sh http://10.0.0.2/scripts/device-passthrough.sh
        chmod +x /tmp/device-passthrough.sh
        /tmp/device-passthrough.sh
        
        # Download and run Kubernetes control plane initialization
        wget -O /tmp/k8s-init.sh http://10.0.0.2/scripts/k8s-control-plane-init.sh
        chmod +x /tmp/k8s-init.sh
        /tmp/k8s-init.sh
        ;;
    "worker")
        echo "Configuring as Kubernetes worker..."
        "$STATE_SCRIPT" save "k8s-role" "worker"
        ;;
esac

# Report provisioning complete
"$STATE_SCRIPT" report "ready" "Machine provisioning complete"

echo "Machine provisioning completed successfully"
EOF

# Create basic Kubernetes configuration file
sudo tee "$HTTP_ROOT/scripts/kubernetes-config.yaml" > /dev/null <<'K8S_CONFIG_EOF'
# Basic Kubernetes configuration for stateless machines
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: https://10.0.0.20:6443
  name: homelab
contexts:
- context:
    cluster: homelab
    user: admin
  name: homelab
current-context: homelab
users:
- name: admin
  user: {}
K8S_CONFIG_EOF

# Make scripts executable
sudo chmod +x "$HTTP_ROOT/scripts/"*.sh
sudo chmod +x "$HTTP_ROOT/scripts/"*.py

# Generate cloud-init configurations for all machines in the registry
echo "Generating cloud-init configurations for all registered machines..."
MACHINE_MACS=$(jq -r '.machines | keys[]' "$MACHINE_CONFIGS_ROOT/registry.json")
for MAC in $MACHINE_MACS; do
    echo "Generating cloud-init for machine $MAC"
    sudo "$HTTP_ROOT/scripts/generate-cloud-init.sh" "$MAC" "$HTTP_ROOT/cloud-init/$MAC" "$MACHINE_CONFIGS_ROOT/registry.json" "$SERVER_IP"
done

# Create PXE boot menu configuration
sudo tee "$TFTP_ROOT/pxelinux.cfg/default" > /dev/null <<EOF
DEFAULT menu.c32
PROMPT 0
MENU TITLE Homelab PXE Boot Menu
TIMEOUT 100

LABEL debian-netinstall
    MENU LABEL Debian Network Install (Auto-provision)
    KERNEL debian-installer/amd64/linux
    APPEND initrd=debian-installer/amd64/initrd.gz auto=true priority=critical preseed/url=http://$SERVER_IP/preseed/preseed.cfg netcfg/get_hostname=unassigned netcfg/get_domain=local debian-installer/allow_unauthenticated_ssl=true

LABEL debian-manual
    MENU LABEL Debian Manual Install
    KERNEL debian-installer/amd64/linux
    APPEND initrd=debian-installer/amd64/initrd.gz

LABEL local
    MENU LABEL Boot from local disk
    LOCALBOOT 0
EOF

# Add live boot option to PXE menu only if files exist
if [ -f "$TFTP_ROOT/live/vmlinuz" ] && [ -s "$TFTP_ROOT/live/vmlinuz" ]; then
    sudo tee -a "$TFTP_ROOT/pxelinux.cfg/default" > /dev/null <<EOF

LABEL debian-stateless
    MENU LABEL Debian Live (Stateless)
    KERNEL $KERNEL_PATH
    APPEND initrd=$INITRD_PATH boot=live fetch=http://$SERVER_IP/live/live/filesystem.squashfs ip=dhcp root=/dev/ram0 cloud-config-url=http://$SERVER_IP/cloud-init/\${net:mac}/
EOF
    echo "Live boot option added to PXE menu"
fi

# Create GRUB configuration for UEFI booting with conditional Alpine support
if [ "$ALPINE_AVAILABLE" = true ]; then
    sudo tee "$TFTP_ROOT/grub/grub.cfg" > /dev/null <<EOF
set default="0"
set timeout=10

menuentry "Alpine Linux (Stateless)" {
    linux /alpine/vmlinuz-lts console=tty0 console=ttyS0,115200n8 modloop=http://$SERVER_IP/alpine/boot/modloop-lts alpine_repo=http://dl-cdn.alpinelinux.org/alpine/v3.18/main apkovl=http://$SERVER_IP/alpine/apkovl/kubernetes.apkovl.tar.gz
    initrd /alpine/initramfs-lts
}

menuentry "Debian Network Install (Auto-provision)" {
    linux /debian-installer/amd64/linux auto=true priority=critical preseed/url=http://$SERVER_IP/preseed/preseed.cfg netcfg/get_hostname=unassigned netcfg/get_domain=local debian-installer/allow_unauthenticated_ssl=true
    initrd /debian-installer/amd64/initrd.gz
}

menuentry "Debian Manual Install" {
    linux /debian-installer/amd64/linux
    initrd /debian-installer/amd64/initrd.gz
}

menuentry "Boot from local disk" {
    exit
}
EOF
    echo "GRUB configured with Alpine Linux stateless boot as default"
else
    sudo tee "$TFTP_ROOT/grub/grub.cfg" > /dev/null <<EOF
set default="0"
set timeout=10

menuentry "Debian Network Install (Auto-provision)" {
    linux /debian-installer/amd64/linux auto=true priority=critical preseed/url=http://$SERVER_IP/preseed/preseed.cfg netcfg/get_hostname=unassigned netcfg/get_domain=local debian-installer/allow_unauthenticated_ssl=true
    initrd /debian-installer/amd64/initrd.gz
}

menuentry "Debian Manual Install" {
    linux /debian-installer/amd64/linux
    initrd /debian-installer/amd64/initrd.gz
}

menuentry "Boot from local disk" {
    exit
}
EOF
    echo "GRUB configured with Debian installer (Alpine not available)"
fi

# Add live boot option only if files exist
if [ -f "$TFTP_ROOT/live/vmlinuz" ] && [ -s "$TFTP_ROOT/live/vmlinuz" ]; then
    sudo tee -a "$TFTP_ROOT/grub/grub.cfg" > /dev/null <<EOF

menuentry "Debian Live (Stateless)" {
    linux /live/vmlinuz boot=live fetch=http://$SERVER_IP/live/live/filesystem.squashfs ip=dhcp root=/dev/ram0 cloud-config-url=http://$SERVER_IP/cloud-init/\${net:mac}/
    initrd /live/initrd.img
}
EOF
    echo "Live boot option added to GRUB menu"
else
    echo "Live boot files not available - using network installer only"
fi

# Create preseed configuration for automated installation
sudo tee "$HTTP_ROOT/preseed/preseed.cfg" > /dev/null <<EOF
# Debian preseed configuration for automated installation
d-i debian-installer/locale string en_US
d-i console-setup/ask_detect boolean false
d-i keyboard-configuration/xkb-keymap select us

# Network configuration
d-i netcfg/choose_interface select auto
d-i netcfg/get_domain string local
d-i netcfg/wireless_wep string

# Mirror settings
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string

# Account setup
d-i passwd/root-login boolean true
d-i passwd/root-password password changeme
d-i passwd/root-password-again password changeme
d-i passwd/user-fullname string Admin User
d-i passwd/username string admin
d-i passwd/user-password password changeme
d-i passwd/user-password-again password changeme

# Clock and time zone setup
d-i clock-setup/utc boolean true
d-i time/zone string US/Eastern
d-i clock-setup/ntp boolean true

# Partitioning
d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true

# Base system installation
d-i base-installer/install-recommends boolean false
d-i base-installer/kernel/image string linux-image-amd64

# Package selection
tasksel tasksel/first multiselect standard, ssh-server
d-i pkgsel/include string curl wget jq python3
d-i pkgsel/upgrade select none
popularity-contest popularity-contest/participate boolean false

# Boot loader installation
d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true
d-i grub-installer/bootdev string default

# Finishing up the installation
d-i finish-install/reboot_in_progress note

# Late command to run machine provisioning
d-i preseed/late_command string \\
    in-target wget -O /tmp/provision.sh http://$SERVER_IP/scripts/provision-machine.sh; \\
    in-target chmod +x /tmp/provision.sh; \\
    in-target /tmp/provision.sh
EOF

# Configure nginx to serve HTTP content
sudo tee /etc/nginx/sites-available/pxe-server > /dev/null <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    
    root $HTTP_ROOT;
    index index.html index.htm;
    
    server_name _;
    
    location / {
        try_files \$uri \$uri/ =404;
        autoindex on;
    }
    
    location /api/ {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

# Enable nginx site
sudo ln -sf /etc/nginx/sites-available/pxe-server /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default

# Test nginx configuration
sudo nginx -t

# Configure tftpd-hpa
sudo tee /etc/default/tftpd-hpa > /dev/null <<EOF
TFTP_USERNAME="tftp"
TFTP_DIRECTORY="$TFTP_ROOT"
TFTP_ADDRESS="0.0.0.0:69"
TFTP_OPTIONS="--secure"
EOF

# Restart services
sudo systemctl restart tftpd-hpa
sudo systemctl enable tftpd-hpa

sudo systemctl restart nginx
sudo systemctl enable nginx
sudo systemctl enable machine-state-api
sudo systemctl start machine-state-api

echo "TFTP and HTTP servers are set up for network booting"
echo "TFTP server serving from: $TFTP_ROOT"
echo "HTTP server serving from: $HTTP_ROOT"
echo "State API running on port 8080"
echo "Next server (TFTP): $SERVER_IP"
echo ""
echo "Machine registry created with your test machine (a8:a1:59:41:29:0f)."
echo "Edit $MACHINE_CONFIGS_ROOT/registry.json to add more machines or update configurations."
echo ""
echo "Configure your network router with PXE options:"
echo "  - Option 66 (TFTP Server): $SERVER_IP"
echo "  - Option 67 (Boot Filename): bootnetx64.efi (for UEFI) or pxelinux.0 (for BIOS)"
echo "  - TFTP Server: $SERVER_IP"
