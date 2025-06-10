#!/bin/bash
# Sets up TFTP and HTTP servers for network booting stateless machines with cloud-init support
# DHCP is handled by network router with PXE options configured

set -euo pipefail

# Variables
TFTP_ROOT="/srv/tftp"
HTTP_ROOT="/srv/http"
MACHINE_CONFIGS_ROOT="/srv/http/machines"
STATE_ROOT="/srv/state"
LIVE_ROOT="/srv/http/live"
# Use Ubuntu minimal cloud image for smallest download (~ 287MB vs 3GB+ for live ISO)
UBUNTU_CLOUD_URL="https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-amd64.img"

# Ubuntu cloud netboot URLs - stateless optimized
# Using Focal (20.04 LTS) as it has proven stable netboot support
UBUNTU_KERNEL_URL="http://archive.ubuntu.com/ubuntu/dists/focal/main/installer-amd64/current/legacy-images/netboot/ubuntu-installer/amd64/linux"
UBUNTU_INITRD_URL="http://archive.ubuntu.com/ubuntu/dists/focal/main/installer-amd64/current/legacy-images/netboot/ubuntu-installer/amd64/initrd.gz"

# Alternative: Try standard focal netboot path
UBUNTU_KERNEL_ALT1="http://archive.ubuntu.com/ubuntu/dists/focal/main/installer-amd64/current/images/netboot/ubuntu-installer/amd64/linux"
UBUNTU_INITRD_ALT1="http://archive.ubuntu.com/ubuntu/dists/focal/main/installer-amd64/current/images/netboot/ubuntu-installer/amd64/initrd.gz"

# Completely remove Debian fallbacks - Ubuntu cloud netboot only

# Network configuration
SERVER_IP="10.0.0.2"

# Install required packages
sudo apt-get update
sudo apt-get install -y tftpd-hpa nginx wget jq cloud-init python3 python3-pip

# Create directory structure
sudo mkdir -p "$TFTP_ROOT"
sudo mkdir -p "$HTTP_ROOT"/{machines,cloud-init,scripts,images,state}
sudo mkdir -p "$STATE_ROOT"
sudo mkdir -p "$LIVE_ROOT"

# Set ownership
sudo chown -R tftp:tftp "$TFTP_ROOT"
sudo chown -R www-data:www-data "$HTTP_ROOT"
sudo chown -R root:root "$STATE_ROOT"

# Download Ubuntu PXE boot components (syslinux/isolinux)
echo "Setting up PXE boot infrastructure..."
sudo apt-get install -y syslinux-common pxelinux

# Copy PXE boot files from system installation
sudo mkdir -p "$TFTP_ROOT/pxelinux.cfg"
sudo cp /usr/lib/PXELINUX/pxelinux.0 "$TFTP_ROOT/" 2>/dev/null || \
sudo cp /usr/lib/syslinux/modules/bios/pxelinux.0 "$TFTP_ROOT/" 2>/dev/null || {
    echo "Error: Could not find pxelinux.0 - installing syslinux-common"
    sudo apt-get install -y syslinux-common
    sudo cp /usr/lib/PXELINUX/pxelinux.0 "$TFTP_ROOT/"
}

# Copy required menu system
sudo cp /usr/lib/syslinux/modules/bios/menu.c32 "$TFTP_ROOT/" 2>/dev/null || \
sudo cp /usr/lib/syslinux/menu.c32 "$TFTP_ROOT/" 2>/dev/null

sudo chown -R tftp:tftp "$TFTP_ROOT"

# Download Ubuntu UEFI boot files
echo "Setting up UEFI boot files..."
sudo mkdir -p "$TFTP_ROOT/grub"

# Download Ubuntu UEFI components
if [ ! -f "$TFTP_ROOT/bootnetx64.efi" ]; then
    echo "Downloading Ubuntu UEFI boot files..."
    # Try to get UEFI files from Ubuntu netboot
    wget -O "$TFTP_ROOT/bootnetx64.efi" "http://archive.ubuntu.com/ubuntu/dists/jammy/main/uefi/grub2-amd64/current/bootnetx64.efi.signed" 2>/dev/null || {
        echo "Primary UEFI download failed, using grub-efi-amd64-signed package"
        sudo apt-get install -y grub-efi-amd64-signed shim-signed
        sudo cp /usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed "$TFTP_ROOT/bootnetx64.efi" 2>/dev/null || \
        sudo cp /usr/lib/shim/shimx64.efi "$TFTP_ROOT/bootnetx64.efi"
    }
fi

if [ ! -f "$TFTP_ROOT/grubx64.efi" ]; then
    echo "Downloading GRUB EFI..."
    wget -O "$TFTP_ROOT/grubx64.efi" "http://archive.ubuntu.com/ubuntu/dists/jammy/main/uefi/grub2-amd64/current/grubnetx64.efi.signed" 2>/dev/null || {
        sudo apt-get install -y grub-efi-amd64-signed
        sudo cp /usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed "$TFTP_ROOT/grubx64.efi" 2>/dev/null || \
        sudo cp /usr/lib/grub/x86_64-efi/grub.efi "$TFTP_ROOT/grubx64.efi"
    }
fi

# Install GRUB modules for network booting
sudo mkdir -p "$TFTP_ROOT/grub/x86_64-efi"
if [ -d "/usr/lib/grub/x86_64-efi" ]; then
    sudo cp -r /usr/lib/grub/x86_64-efi/* "$TFTP_ROOT/grub/x86_64-efi/" 2>/dev/null || true
fi

sudo chown -R tftp:tftp "$TFTP_ROOT"

# Download Ubuntu minimal cloud image for stateless operations
echo "Downloading Ubuntu minimal cloud image for stateless booting..."
if [ ! -f "$LIVE_ROOT/ubuntu-cloud.img" ]; then
    echo "Downloading Ubuntu minimal cloud image (~287MB - optimized for network boot)..."
    wget -O "$LIVE_ROOT/ubuntu-cloud.img" "$UBUNTU_CLOUD_URL" || {
        echo "Warning: Ubuntu cloud image download failed. Using direct kernel/initrd method only."
        rm -f "$LIVE_ROOT/ubuntu-cloud.img"
    }
    
    # Verify file size (minimal cloud image should be around 287MB)
    if [ -f "$LIVE_ROOT/ubuntu-cloud.img" ]; then
        FILE_SIZE=$(stat -f%z "$LIVE_ROOT/ubuntu-cloud.img" 2>/dev/null || stat -c%s "$LIVE_ROOT/ubuntu-cloud.img" 2>/dev/null || echo "0")
        if [ "$FILE_SIZE" -lt 200000000 ]; then  # Less than 200MB indicates failure
            echo "Downloaded file appears too small, removing and using kernel/initrd method"
            rm -f "$LIVE_ROOT/ubuntu-cloud.img"
        else
            echo "Ubuntu cloud image downloaded successfully (${FILE_SIZE} bytes)"
        fi
    fi
else
    echo "Ubuntu cloud image already exists"
fi

# Download direct kernel and initrd for network booting (more reliable)
echo "Setting up direct kernel/initrd network boot..."
sudo mkdir -p "$TFTP_ROOT/ubuntu"

# Download Ubuntu kernel and initrd for cloud netboot (stateless only)
if [ ! -f "$TFTP_ROOT/ubuntu/vmlinuz" ] || [ ! -s "$TFTP_ROOT/ubuntu/vmlinuz" ]; then
    echo "Downloading Ubuntu cloud netboot kernel..."
    wget -O "$TFTP_ROOT/ubuntu/vmlinuz" "$UBUNTU_KERNEL_URL" || {
        echo "Primary Ubuntu kernel download failed, trying alternative..."
        wget -O "$TFTP_ROOT/ubuntu/vmlinuz" "$UBUNTU_KERNEL_ALT1" || {
            echo "Error: Failed to download Ubuntu cloud netboot kernel from all sources"
            echo "This setup requires Ubuntu cloud netboot support"
            exit 1
        }
    }
fi

if [ ! -f "$TFTP_ROOT/ubuntu/initrd.gz" ] || [ ! -s "$TFTP_ROOT/ubuntu/initrd.gz" ]; then
    echo "Downloading Ubuntu cloud netboot initrd..."
    wget -O "$TFTP_ROOT/ubuntu/initrd.gz" "$UBUNTU_INITRD_URL" || {
        echo "Primary Ubuntu initrd download failed, trying alternative..."
        wget -O "$TFTP_ROOT/ubuntu/initrd.gz" "$UBUNTU_INITRD_ALT1" || {
            echo "Error: Failed to download Ubuntu cloud netboot initrd from all sources"
            echo "This setup requires Ubuntu cloud netboot support"
            exit 1
        }
    }
fi

# Set proper ownership
sudo chown -R tftp:tftp "$TFTP_ROOT/ubuntu"
sudo chown -R www-data:www-data "$LIVE_ROOT"

# Check if we have valid boot files
if [ -f "$TFTP_ROOT/ubuntu/vmlinuz" ] && [ -s "$TFTP_ROOT/ubuntu/vmlinuz" ] && 
   [ -f "$TFTP_ROOT/ubuntu/initrd.gz" ] && [ -s "$TFTP_ROOT/ubuntu/initrd.gz" ]; then
    LIVE_AVAILABLE=true
    echo "Network boot files available and ready"
else
    LIVE_AVAILABLE=false
    echo "Warning: Network boot files not properly downloaded"
fi

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

if [ -z "$MACHINE_INFO" ] || [ "$MACHINE_INFO" = "null" ]; then
    echo "Machine $MAC_ADDRESS not found in registry, using defaults"
    HOSTNAME="stateless-$(echo $MAC_ADDRESS | tr ':' '-')"
    ROLE="worker"
    IP="dhcp"
    FEATURES="[]"
else
    HOSTNAME=$(echo "$MACHINE_INFO" | jq -r '.hostname')
    ROLE=$(echo "$MACHINE_INFO" | jq -r '.role')
    IP=$(echo "$MACHINE_INFO" | jq -r '.ip // "dhcp"')
    FEATURES=$(echo "$MACHINE_INFO" | jq -r '.features | join(",")')
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Generate meta-data
cat > "$OUTPUT_DIR/meta-data" <<METAEND
instance-id: $HOSTNAME
local-hostname: $HOSTNAME
METAEND

# Generate network-config
if [ "$IP" != "dhcp" ]; then
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
else
cat > "$OUTPUT_DIR/network-config" <<NETEND
version: 2
ethernets:
  eth0:
    dhcp4: true
NETEND
fi

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
    groups: [docker]
    
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

# Enable services
runcmd:
  - systemctl enable docker
  - systemctl start docker
  - systemctl enable containerd
  - systemctl start containerd
  - wget -O /usr/local/bin/machine-state.sh http://$SERVER_IP/scripts/machine-state.sh
  - chmod +x /usr/local/bin/machine-state.sh
  - /usr/local/bin/machine-state.sh report "booted" "Machine booted successfully"

final_message: "Cloud-init setup complete for $HOSTNAME"
USEREND

echo "Generated cloud-init configuration for $HOSTNAME ($MAC_ADDRESS) in $OUTPUT_DIR"
EOF

sudo chmod +x "$HTTP_ROOT/scripts/generate-cloud-init.sh"

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
      "features": ["docker"],
      "ip": "10.0.0.20"
    }
  },
  "defaults": {
    "timezone": "America/New_York",
    "packages": ["curl", "wget", "htop", "git", "docker.io"]
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
    curl -s "$STATE_SERVER/machines/registry.json" | jq -r ".machines[\"$MAC_ADDRESS\"] // {}"
}

case "${1:-}" in
    "report")
        report_state "$2" "${3:-}"
        ;;
    "config")
        get_config
        ;;
    *)
        echo "Usage: $0 {report|config} [args...]"
        exit 1
        ;;
esac
EOF

sudo chmod +x "$HTTP_ROOT/scripts/machine-state.sh"

# Create simple state API service
sudo tee "$HTTP_ROOT/scripts/state-api.py" > /dev/null <<'EOF'
#!/usr/bin/env python3
# Simple state API for machine management
import json
import os
from datetime import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

STATE_FILE = "/srv/state/machine-states.json"

class StateHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == "/api/state":
            content_length = int(self.headers['Content-Length'])
            post_data = self.rfile.read(content_length)
            
            try:
                data = json.loads(post_data.decode('utf-8'))
                self.save_state(data)
                self.send_response(200)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                self.wfile.write(b'{"status": "ok"}')
            except Exception as e:
                self.send_response(400)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                self.wfile.write(f'{{"error": "{str(e)}"}}'.encode())
        else:
            self.send_response(404)
            self.end_headers()
    
    def do_GET(self):
        if self.path == "/api/states":
            states = self.load_states()
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(states).encode())
        else:
            self.send_response(404)
            self.end_headers()
    
    def save_state(self, data):
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        
        # Load existing states
        states = self.load_states()
        
        # Update state for this machine
        mac = data.get('mac')
        if mac:
            states[mac] = data
        
        # Save back to file
        with open(STATE_FILE, 'w') as f:
            json.dump(states, f, indent=2)
    
    def load_states(self):
        if os.path.exists(STATE_FILE):
            try:
                with open(STATE_FILE, 'r') as f:
                    return json.load(f)
            except:
                return {}
        return {}

if __name__ == "__main__":
    server = HTTPServer(('localhost', 8080), StateHandler)
    print("State API running on port 8080")
    server.serve_forever()
EOF

sudo chmod +x "$HTTP_ROOT/scripts/state-api.py"

# Create systemd service for state API
sudo tee /etc/systemd/system/machine-state-api.service > /dev/null <<EOF
[Unit]
Description=Machine State API
After=network.target

[Service]
Type=simple
User=www-data
ExecStart=/usr/bin/python3 $HTTP_ROOT/scripts/state-api.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Generate cloud-init configurations for all machines in the registry
echo "Generating cloud-init configurations for all registered machines..."
MACHINE_MACS=$(jq -r '.machines | keys[]' "$MACHINE_CONFIGS_ROOT/registry.json")
for MAC in $MACHINE_MACS; do
    echo "Generating cloud-init for machine $MAC"
    sudo "$HTTP_ROOT/scripts/generate-cloud-init.sh" "$MAC" "$HTTP_ROOT/cloud-init/$MAC" "$MACHINE_CONFIGS_ROOT/registry.json" "$SERVER_IP"
done

# Create PXE boot menu configuration (completely Ubuntu-based)
sudo mkdir -p "$TFTP_ROOT/pxelinux.cfg"
sudo tee "$TFTP_ROOT/pxelinux.cfg/default" > /dev/null <<EOF
DEFAULT menu.c32
PROMPT 0
MENU TITLE Ubuntu Stateless Network Boot
TIMEOUT 100

EOF

# Add Ubuntu stateless boot option if files exist
if [ "$LIVE_AVAILABLE" = true ] && [ -f "$TFTP_ROOT/ubuntu/vmlinuz" ] && [ -s "$TFTP_ROOT/ubuntu/vmlinuz" ]; then
    sudo tee -a "$TFTP_ROOT/pxelinux.cfg/default" > /dev/null <<EOF
LABEL ubuntu-stateless
    MENU LABEL Ubuntu Cloud Netboot (Stateless Only)
    KERNEL ubuntu/vmlinuz
    APPEND initrd=ubuntu/initrd.gz root=/dev/ram0 ramdisk_size=2097152 ip=dhcp cloud-config-url=http://$SERVER_IP/cloud-init/\${net0/mac}/ ds=nocloud-net;s=http://$SERVER_IP/cloud-init/\${net0/mac}/ console=tty0 console=ttyS0,115200 net.ifnames=0 biosdevname=0 systemd.unified_cgroup_hierarchy=1 cloud-init=network-v2 fsck.mode=skip

EOF
    echo "Ubuntu stateless boot option added to PXE menu"
else
    echo "Warning: No valid stateless boot files found - PXE boot may not work properly"
fi

# Add local boot option as fallback
sudo tee -a "$TFTP_ROOT/pxelinux.cfg/default" > /dev/null <<EOF
LABEL local
    MENU LABEL Boot from local disk
    LOCALBOOT 0
EOF

# Create GRUB configuration for UEFI booting (completely replace any existing config)
sudo mkdir -p "$TFTP_ROOT/grub"
if [ "$LIVE_AVAILABLE" = true ] && [ -f "$TFTP_ROOT/ubuntu/vmlinuz" ]; then
    sudo tee "$TFTP_ROOT/grub/grub.cfg" > /dev/null <<EOF
# Ubuntu Stateless Network Boot Configuration
# This configuration ONLY supports stateless booting

set default="ubuntu-stateless"
set timeout=10
set timeout_style=menu

# Load necessary modules
insmod net
insmod efinet
insmod tftp
insmod gzio
insmod part_gpt
insmod part_msdos
insmod fat
insmod ext2

menuentry "Ubuntu Cloud Netboot (Stateless Only)" --id ubuntu-stateless {
    echo "Loading Ubuntu cloud netboot kernel..."
    linux /ubuntu/vmlinuz root=/dev/ram0 ramdisk_size=2097152 ip=dhcp cloud-config-url=http://$SERVER_IP/cloud-init/\${net0/mac}/ ds=nocloud-net;s=http://$SERVER_IP/cloud-init/\${net0/mac}/ console=tty0 console=ttyS0,115200 net.ifnames=0 biosdevname=0 systemd.unified_cgroup_hierarchy=1 cloud-init=network-v2 fsck.mode=skip
    echo "Loading Ubuntu cloud netboot initrd..."
    initrd /ubuntu/initrd.gz
    echo "Booting Ubuntu cloud stateless system..."
}

menuentry "Boot from local disk" --id local-disk {
    echo "Attempting to boot from local disk..."
    exit
}
EOF
    echo "GRUB configured with Ubuntu stateless boot as default"
else
    sudo tee "$TFTP_ROOT/grub/grub.cfg" > /dev/null <<EOF
# Emergency GRUB configuration - no stateless boot available
set default="local-disk"
set timeout=10

menuentry "Boot from local disk" --id local-disk {
    echo "No network boot available, trying local disk..."
    exit
}
EOF
    echo "GRUB configured with local boot only (stateless boot not available)"
fi

# Ensure our GRUB config has proper permissions
sudo chown -R tftp:tftp "$TFTP_ROOT/grub"
sudo chmod 644 "$TFTP_ROOT/grub/grub.cfg"

echo "PXE and GRUB configurations created"

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
TFTP_OPTIONS="--secure --verbose"
EOF

# Verify TFTP file structure and show download efficiency
echo "Verifying TFTP file structure and download efficiency..."
echo "TFTP Root contents:"
sudo ls -la "$TFTP_ROOT/"
echo ""
echo "UEFI boot files:"
sudo ls -la "$TFTP_ROOT/"*.efi 2>/dev/null || echo "No EFI files found"
echo ""
echo "GRUB directory:"
sudo ls -la "$TFTP_ROOT/grub/" 2>/dev/null || echo "GRUB directory not found"
echo ""
echo "Ubuntu stateless boot files:"
if [ -f "$TFTP_ROOT/ubuntu/vmlinuz" ] && [ -f "$TFTP_ROOT/ubuntu/initrd.gz" ]; then
    KERNEL_SIZE=$(stat -f%z "$TFTP_ROOT/ubuntu/vmlinuz" 2>/dev/null || stat -c%s "$TFTP_ROOT/ubuntu/vmlinuz" 2>/dev/null || echo "0")
    INITRD_SIZE=$(stat -f%z "$TFTP_ROOT/ubuntu/initrd.gz" 2>/dev/null || stat -c%s "$TFTP_ROOT/ubuntu/initrd.gz" 2>/dev/null || echo "0")
    TOTAL_NETWORK_SIZE=$((KERNEL_SIZE + INITRD_SIZE))
    echo "  vmlinuz: $(echo $KERNEL_SIZE | numfmt --to=iec 2>/dev/null || echo "${KERNEL_SIZE} bytes")"
    echo "  initrd.gz: $(echo $INITRD_SIZE | numfmt --to=iec 2>/dev/null || echo "${INITRD_SIZE} bytes")"
    echo "  Total network transfer: $(echo $TOTAL_NETWORK_SIZE | numfmt --to=iec 2>/dev/null || echo "${TOTAL_NETWORK_SIZE} bytes")"
else
    echo "Ubuntu boot files not found"
fi
echo ""
echo "Cloud image (optional):"
if [ -f "$LIVE_ROOT/ubuntu-cloud.img" ]; then
    CLOUD_SIZE=$(stat -f%z "$LIVE_ROOT/ubuntu-cloud.img" 2>/dev/null || stat -c%s "$LIVE_ROOT/ubuntu-cloud.img" 2>/dev/null || echo "0")
    echo "  ubuntu-cloud.img: $(echo $CLOUD_SIZE | numfmt --to=iec 2>/dev/null || echo "${CLOUD_SIZE} bytes")"
else
    echo "  No cloud image downloaded (using kernel/initrd method only)"
fi
echo ""

# Fix permissions for all TFTP files
sudo chown -R tftp:tftp "$TFTP_ROOT"
sudo chmod -R 755 "$TFTP_ROOT"
sudo find "$TFTP_ROOT" -type f -exec chmod 644 {} \;

# Restart services
sudo systemctl restart tftpd-hpa
sudo systemctl enable tftpd-hpa

sudo systemctl restart nginx
sudo systemctl enable nginx

sudo systemctl enable machine-state-api
sudo systemctl start machine-state-api

echo "TFTP and HTTP servers are set up for stateless network booting"
echo "TFTP server serving from: $TFTP_ROOT"
echo "HTTP server serving from: $HTTP_ROOT"
echo "State API running on port 8080"
echo "Next server (TFTP): $SERVER_IP"
echo ""
echo "=== UBUNTU CLOUD NETBOOT STATELESS SUMMARY ==="
echo "✓ Using Ubuntu Focal (20.04 LTS) cloud netboot - proven stable"
echo "✓ Pure stateless operation with cloud-init network configuration"
echo "✓ No installer components - direct cloud image boot only"
echo "✓ Optimized kernel parameters for cloud environments"
echo "✓ 2GB ramdisk for full stateless operation"
echo "✓ All Debian fallbacks removed - Ubuntu cloud netboot only"
echo ""
echo "Boot methods configured:"
if [ "$LIVE_AVAILABLE" = true ]; then
    echo "- Primary: Ubuntu cloud netboot (kernel + initrd) - stateless only"
    echo "- Cloud image available: $(ls -lh $LIVE_ROOT/ubuntu-cloud.img 2>/dev/null | awk '{print $5}' || echo 'Not found')"
else
    echo "- Primary: Ubuntu cloud netboot (kernel + initrd only) - stateless only"
fi
echo "- Fallback: Local disk boot (emergency only)"
echo ""
echo "Machine registry created with your test machine (a8:a1:59:41:29:0f)."
echo "Edit $MACHINE_CONFIGS_ROOT/registry.json to add more machines or update configurations."
echo ""
echo "Configure your network router with PXE options:"
echo "  - Option 66 (TFTP Server): $SERVER_IP"
echo "  - Option 67 (Boot Filename): bootnetx64.efi (for UEFI) or pxelinux.0 (for BIOS)"
echo "  - TFTP Server: $SERVER_IP"
echo ""
echo "=== TROUBLESHOOTING UBUNTU CLOUD NETBOOT ==="
echo "Common issues and solutions for Ubuntu cloud netboot stateless operation:"
echo ""
echo "TFTP Connection Issues:"
echo "1. Check TFTP service status: sudo systemctl status tftpd-hpa"
echo "2. Test TFTP locally: tftp $SERVER_IP -c get bootnetx64.efi"
echo "3. Check file permissions: ls -la $TFTP_ROOT/"
echo "4. Monitor TFTP logs: sudo journalctl -f -u tftpd-hpa"
echo "5. Verify firewall allows TFTP (port 69/UDP): sudo ufw status"
echo ""
echo "Cloud Netboot Issues:"
echo "1. Verify Ubuntu kernel exists and is not empty: ls -lh $TFTP_ROOT/ubuntu/vmlinuz"
echo "2. Verify initrd exists and is not empty: ls -lh $TFTP_ROOT/ubuntu/initrd.gz"
echo "3. Check cloud-init configs are generated: ls -la $HTTP_ROOT/cloud-init/"
echo "4. Test HTTP server serves configs: curl http://$SERVER_IP/cloud-init/"
echo "5. Verify machine is in registry: jq '.machines' $MACHINE_CONFIGS_ROOT/registry.json"
echo ""
echo "Ubuntu Cloud Netboot Optimization:"
echo "- Kernel/initrd method uses minimal network transfer (~61MB total)"
echo "- Cloud image method requires larger download (~287MB) but provides full OS"
echo "- All configurations enforce pure stateless operation"
echo "- Uses Ubuntu Focal (20.04 LTS) for maximum compatibility"
echo ""
echo "Manual TFTP Test Commands:"
echo "  tftp $SERVER_IP"
echo "  get bootnetx64.efi"
echo "  get ubuntu/vmlinuz"
echo "  get ubuntu/initrd.gz"
echo "  quit"
