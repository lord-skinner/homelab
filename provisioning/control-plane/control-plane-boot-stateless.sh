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

# Skip live boot setup for now - focus on network installer
echo "Skipping live boot setup - using network installer as primary method"
echo "Live boot can be configured later if needed"

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
      "features": ["fernetes", "nfs", "storage"],
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

# Create basic API server for state management
sudo tee "$HTTP_ROOT/scripts/state-api.py" > /dev/null <<'EOF'
#!/usr/bin/env python3
"""
Simple state management API server for machine provisioning
"""
import json
import os
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import sqlite3
from datetime import datetime

STATE_DB = '/srv/state/machines.db'
REGISTRY_FILE = '/srv/http/machines/registry.json'

class StateHandler(BaseHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        # Initialize database
        self.init_db()
        super().__init__(*args, **kwargs)
    
    def init_db(self):
        """Initialize SQLite database for state management"""
        os.makedirs(os.path.dirname(STATE_DB), exist_ok=True)
        conn = sqlite3.connect(STATE_DB)
        cursor = conn.cursor()
        
        # Create tables
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS machine_states (
                mac TEXT PRIMARY KEY,
                hostname TEXT,
                state TEXT,
                message TEXT,
                timestamp TEXT
            )
        ''')
        
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS machine_data (
                mac TEXT,
                key TEXT,
                value TEXT,
                timestamp TEXT,
                PRIMARY KEY (mac, key)
            )
        ''')
        
        conn.commit()
        conn.close()
    
    def do_GET(self):
        """Handle GET requests"""
        path = urlparse(self.path).path
        
        if path.startswith('/api/config/'):
            mac = path.split('/')[-1]
            self.get_machine_config(mac)
        elif path.startswith('/api/data/'):
            parts = path.split('/')
            mac, key = parts[-2], parts[-1]
            self.get_machine_data(mac, key)
        elif path == '/api/states':
            self.get_all_states()
        else:
            self.send_error(404)
    
    def do_POST(self):
        """Handle POST requests"""
        path = urlparse(self.path).path
        content_length = int(self.headers['Content-Length'])
        post_data = self.rfile.read(content_length).decode('utf-8')
        data = json.loads(post_data)
        
        if path == '/api/state':
            self.update_machine_state(data)
        elif path == '/api/data':
            self.save_machine_data(data)
        else:
            self.send_error(404)
    
    def get_machine_config(self, mac):
        """Get configuration for a specific machine"""
        try:
            with open(REGISTRY_FILE, 'r') as f:
                registry = json.load(f)
            
            if mac in registry['machines']:
                config = registry['machines'][mac]
                config['defaults'] = registry['defaults']
                self.send_json_response(config)
            else:
                # Return default configuration for unknown machines
                default_config = {
                    "hostname": f"unknown-{mac.replace(':', '')}",
                    "role": "worker",
                    "architecture": "amd64",
                    "features": ["kubernetes"],
                    "defaults": registry['defaults']
                }
                self.send_json_response(default_config)
        except Exception as e:
            self.send_error(500, str(e))
    
    def update_machine_state(self, data):
        """Update machine state"""
        try:
            conn = sqlite3.connect(STATE_DB)
            cursor = conn.cursor()
            
            cursor.execute('''
                INSERT OR REPLACE INTO machine_states 
                (mac, hostname, state, message, timestamp)
                VALUES (?, ?, ?, ?, ?)
            ''', (data['mac'], data['hostname'], data['state'], 
                  data['message'], data['timestamp']))
            
            conn.commit()
            conn.close()
            
            self.send_json_response({"status": "success"})
        except Exception as e:
            self.send_error(500, str(e))
    
    def save_machine_data(self, data):
        """Save persistent machine data"""
        try:
            conn = sqlite3.connect(STATE_DB)
            cursor = conn.cursor()
            
            cursor.execute('''
                INSERT OR REPLACE INTO machine_data 
                (mac, key, value, timestamp)
                VALUES (?, ?, ?, ?)
            ''', (data['mac'], data['key'], data['value'], 
                  datetime.now().isoformat()))
            
            conn.commit()
            conn.close()
            
            self.send_json_response({"status": "success"})
        except Exception as e:
            self.send_error(500, str(e))
    
    def get_machine_data(self, mac, key):
        """Get persistent machine data"""
        try:
            conn = sqlite3.connect(STATE_DB)
            cursor = conn.cursor()
            
            cursor.execute(
                'SELECT value FROM machine_data WHERE mac = ? AND key = ?',
                (mac, key)
            )
            result = cursor.fetchone()
            conn.close()
            
            if result:
                self.send_json_response({"value": result[0]})
            else:
                self.send_json_response({"value": None})
        except Exception as e:
            self.send_error(500, str(e))
    
    def get_all_states(self):
        """Get all machine states"""
        try:
            conn = sqlite3.connect(STATE_DB)
            cursor = conn.cursor()
            
            cursor.execute('SELECT * FROM machine_states')
            rows = cursor.fetchall()
            conn.close()
            
            states = []
            for row in rows:
                states.append({
                    "mac": row[0],
                    "hostname": row[1],
                    "state": row[2],
                    "message": row[3],
                    "timestamp": row[4]
                })
            
            self.send_json_response({"states": states})
        except Exception as e:
            self.send_error(500, str(e))
    
    def send_json_response(self, data):
        """Send JSON response"""
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

if __name__ == '__main__':
    server = HTTPServer(('0.0.0.0', 8080), StateHandler)
    print("State API server running on port 8080")
    server.serve_forever()
EOF

# Create systemd service for state API
sudo tee /etc/systemd/system/machine-state-api.service > /dev/null <<EOF
[Unit]
Description=Machine State API Server
After=network.target

[Service]
Type=simple
User=www-data
WorkingDirectory=/srv/http/scripts
ExecStart=/usr/bin/python3 /srv/http/scripts/state-api.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

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

# Create GRUB configuration for UEFI booting
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
