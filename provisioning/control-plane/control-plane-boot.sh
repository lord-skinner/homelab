#!/bin/bash
# Sets up a DHCP and TFTP server for network booting with PXE

set -euo pipefail

# Variables
TFTP_ROOT="/srv/tftp"
PXE_ROOT="/srv/tftp/pxelinux"
HTTP_ROOT="/srv/http"
MACHINE_CONFIGS_ROOT="/srv/http/machines"
STATE_ROOT="/srv/state"
DEBIAN_IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
DEBIAN_IMAGE_NAME="debian-12-generic-amd64.qcow2"
NETBOOT_URL="http://ftp.debian.org/debian/dists/bookworm/main/installer-amd64/current/images/netboot/netboot.tar.gz"

# Network configuration - adjust these for your network
DHCP_SUBNET="10.0.0.0"
DHCP_NETMASK="255.255.255.0"
DHCP_RANGE_START="10.0.0.200"
DHCP_RANGE_END="10.0.0.209"
DHCP_ROUTER="10.0.0.1"
DHCP_DNS="8.8.8.8, 8.8.4.4"
SERVER_IP="10.0.0.10"

# Install required packages
sudo apt-get update
sudo apt-get install -y tftpd-hpa isc-dhcp-server nginx wget jq cloud-init

# Create TFTP root directory if it doesn't exist
sudo mkdir -p "$TFTP_ROOT"
sudo mkdir -p "$PXE_ROOT"
sudo mkdir -p "$HTTP_ROOT"
sudo mkdir -p "$MACHINE_CONFIGS_ROOT"
sudo mkdir -p "$STATE_ROOT"
sudo mkdir -p "$HTTP_ROOT/preseed"
sudo mkdir -p "$HTTP_ROOT/cloud-init"
sudo mkdir -p "$HTTP_ROOT/scripts"
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

# Download Debian cloud image if not already present
if [ ! -f "$TFTP_ROOT/$DEBIAN_IMAGE_NAME" ]; then
    echo "Downloading Debian cloud image..."
    sudo wget -O "$TFTP_ROOT/$DEBIAN_IMAGE_NAME" "$DEBIAN_IMAGE_URL"
    sudo chown tftp:tftp "$TFTP_ROOT/$DEBIAN_IMAGE_NAME"
fi

# Create machine registry and configurations
echo "Setting up machine registry and configurations..."

# Create machine registry
sudo tee "$MACHINE_CONFIGS_ROOT/registry.json" > /dev/null <<EOF
{
  "machines": {
    "00:11:22:33:44:55": {
      "hostname": "k8s-cp-1",
      "role": "control-plane",
      "architecture": "amd64",
      "features": ["kubernetes", "nfs", "storage"],
      "ip": "10.0.0.11",
      "specs": {
        "cpu": "4c/4t",
        "memory": "16GB",
        "storage": "20TB RAID"
      }
    },
    "00:11:22:33:44:56": {
      "hostname": "k8s-worker-1", 
      "role": "worker",
      "architecture": "amd64",
      "features": ["kubernetes", "gpu", "inference"],
      "ip": "10.0.0.12",
      "specs": {
        "cpu": "12c/24t",
        "memory": "64GB",
        "gpu": "RTX 4090 24GB"
      }
    },
    "00:11:22:33:44:57": {
      "hostname": "k8s-worker-2",
      "role": "worker", 
      "architecture": "amd64",
      "features": ["kubernetes", "compute"],
      "ip": "10.0.0.13",
      "specs": {
        "cpu": "14c/20t",
        "memory": "32GB"
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

STATE_SERVER="http://10.0.0.10"
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
wget -O "$STATE_SCRIPT" http://10.0.0.10/scripts/machine-state.sh
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
        wget -O /tmp/device-passthrough.sh http://10.0.0.10/scripts/device-passthrough.sh
        chmod +x /tmp/device-passthrough.sh
        /tmp/device-passthrough.sh
        
        # Download and run Kubernetes control plane initialization
        wget -O /tmp/k8s-init.sh http://10.0.0.10/scripts/k8s-control-plane-init.sh
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

# Copy the Kubernetes and device passthrough scripts to HTTP server
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sudo cp "$SCRIPT_DIR/k8s-control-plane-init.sh" "$HTTP_ROOT/scripts/"
sudo cp "$SCRIPT_DIR/device-passthrough.sh" "$HTTP_ROOT/scripts/"

# Make scripts executable
sudo chmod +x "$HTTP_ROOT/scripts/"*.sh
sudo chmod +x "$HTTP_ROOT/scripts/"*.py

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
sudo systemctl restart nginx
sudo systemctl enable nginx
sudo systemctl enable machine-state-api
sudo systemctl start machine-state-api

echo "DHCP and TFTP servers are set up for network booting"
echo "DHCP server serving range: $DHCP_RANGE_START - $DHCP_RANGE_END"
echo "TFTP server serving from: $TFTP_ROOT"
echo "HTTP server serving from: $HTTP_ROOT"
echo "State API running on port 8080"
echo "Next server (TFTP): $SERVER_IP"
echo ""
echo "Machine registry created with example configurations."
echo "Edit $MACHINE_CONFIGS_ROOT/registry.json to add your machines."
echo ""
echo "Configure your network equipment to use this server ($SERVER_IP) as DHCP server"
echo "or set DHCP option 66 (TFTP server) to $SERVER_IP and option 67 (boot filename) to 'pxelinux.0'"