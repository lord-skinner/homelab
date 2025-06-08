# Homelab PXE Boot with Machine State Management

This enhanced PXE boot system provides automated machine provisioning with persistent state management, allowing each machine to maintain its configuration and boot quickly on subsequent restarts.

## Features

- **Machine Registry**: Central configuration database for all machines
- **State Management**: Track boot progress and maintain persistent data per machine
- **Feature-based Provisioning**: Configure machines based on their intended role and features
- **HTTP API**: RESTful API for machine state and configuration management
- **Real-time Monitoring**: Dashboard to track machine boot progress
- **Automated Installation**: Preseed-based Debian installation with custom provisioning

## Architecture

```
PXE Boot Server (10.0.0.10)
├── DHCP Server (isc-dhcp-server)
├── TFTP Server (tftpd-hpa)
├── HTTP Server (nginx)
│   ├── /machines/registry.json (Machine configurations)
│   ├── /preseed/preseed.cfg (Debian installer config)
│   └── /scripts/ (Provisioning scripts)
└── State API Server (Python, port 8080)
    └── SQLite database (/srv/state/machines.db)
```

## Setup

1. **Run the main setup script:**

   ```bash
   sudo ./control-plane-boot.sh
   ```

2. **Configure your machines in the registry:**

   ```bash
   sudo nano /srv/http/machines/registry.json
   ```

3. **Start monitoring (optional):**
   ```bash
   ./monitor-machines.sh
   ```

## Machine Configuration

Each machine is defined by its MAC address in the registry with the following properties:

```json
{
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
  }
}
```

### Supported Features

- **kubernetes**: Install Kubernetes components (kubelet, kubeadm, kubectl)
- **gpu**: Install NVIDIA drivers and container toolkit
- **nfs**: Set up NFS server for shared storage
- **storage**: Configure additional storage systems
- **compute**: General compute node configuration

### Supported Roles

- **control-plane**: Kubernetes master node
- **worker**: Kubernetes worker node
- **compute**: General compute node

## Management Commands

### Add a new machine:

```bash
./manage-machines.sh add 00:11:22:33:44:88 worker-3 worker amd64 kubernetes compute
```

### Remove a machine:

```bash
./manage-machines.sh remove 00:11:22:33:44:88
```

### List all machines:

```bash
./manage-machines.sh list
```

### Check machine status:

```bash
./manage-machines.sh status
./manage-machines.sh status 00:11:22:33:44:55
```

### View machine configuration:

```bash
./manage-machines.sh config 00:11:22:33:44:55
```

## Monitoring

### Real-time dashboard:

```bash
./monitor-machines.sh
```

### One-time status check:

```bash
./monitor-machines.sh --once
```

## API Endpoints

The state management API provides the following endpoints:

- `GET /api/config/{mac}` - Get machine configuration
- `POST /api/state` - Update machine state
- `POST /api/data` - Save persistent machine data
- `GET /api/data/{mac}/{key}` - Get persistent machine data
- `GET /api/states` - Get all machine states

## Boot Process

1. **PXE Boot**: Machine boots from network and loads Debian installer
2. **Preseed Installation**: Automated Debian installation using preseed configuration
3. **Machine Identification**: System identifies itself by MAC address
4. **Configuration Retrieval**: Downloads machine-specific configuration from API
5. **Feature Provisioning**: Installs and configures features based on machine role
6. **State Reporting**: Reports provisioning progress and final state
7. **Ready**: Machine is ready for use with persistent state maintained

## State Management

Each machine maintains persistent state across reboots:

- **Boot Progress**: Track installation and configuration phases
- **Configuration Data**: Store machine-specific settings
- **Feature Status**: Track which features are installed and configured
- **Error Reporting**: Log and track any provisioning errors

## Network Configuration

- **DHCP Range**: 10.0.0.200 - 10.0.0.209 (for unknown machines)
- **Static IPs**: Assigned per machine in registry (10.0.0.11+)
- **PXE Server**: 10.0.0.10
- **State API**: 10.0.0.10:8080

## Files and Directories

```
/srv/
├── tftp/                           # TFTP root
│   ├── pxelinux.0                 # PXE bootloader
│   ├── pxelinux.cfg/default       # Boot menu
│   └── debian-installer/          # Debian netboot files
├── http/                          # HTTP content
│   ├── machines/registry.json     # Machine registry
│   ├── preseed/preseed.cfg        # Debian preseed config
│   └── scripts/                   # Provisioning scripts
└── state/                         # State database
    └── machines.db                # SQLite database
```

## Troubleshooting

### Check service status:

```bash
sudo systemctl status tftpd-hpa
sudo systemctl status isc-dhcp-server
sudo systemctl status nginx
sudo systemctl status machine-state-api
```

### View logs:

```bash
sudo journalctl -u machine-state-api -f
sudo tail -f /var/log/syslog | grep dhcp
```

### Test API connectivity:

```bash
curl http://10.0.0.10:8080/api/states
curl http://10.0.0.10:8080/api/config/00:11:22:33:44:55
```

### Manual machine provisioning:

```bash
# On the target machine after installation
wget http://10.0.0.10/scripts/provision-machine.sh
chmod +x provision-machine.sh
./provision-machine.sh
```

## Security Considerations

- Change default passwords in preseed configuration
- Configure firewall rules for PXE services
- Use HTTPS for production deployments
- Implement authentication for API endpoints
- Regular backup of machine registry and state database
