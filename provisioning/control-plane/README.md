# Homelab Kubernetes Control Plane Auto-Provisioning

This enhanced PXE boot system provides automated Kubernetes control plane provisioning with persistent state management, device passthrough, and high-availability cluster initialization. The system handles everything from bare metal boot to fully configured Kubernetes control plane nodes.

## Features

- **Machine Registry**: Central configuration database for all machines
- **State Management**: Track boot progress and maintain persistent data per machine
- **Kubernetes Auto-Provisioning**: Automated control plane initialization and cluster setup
- **Device Passthrough**: GPU, NFS, and storage device configuration
- **High Availability**: Multi-master control plane setup with etcd clustering
- **Feature-based Provisioning**: Configure machines based on their intended role and features
- **HTTP API**: RESTful API for machine state and configuration management
- **Real-time Monitoring**: Dashboard to track machine boot progress
- **Cluster Management**: Tools for cluster monitoring, backup, and maintenance
- **Automated Installation**: Preseed-based Debian installation with custom provisioning

## Architecture

```
PXE Boot Server (10.0.0.10)
├── DHCP Server (isc-dhcp-server)
├── TFTP Server (tftpd-hpa)
├── HTTP Server (nginx)
│   ├── /machines/registry.json (Machine configurations)
│   ├── /preseed/preseed.cfg (Debian installer config)
│   └── /scripts/ (Provisioning and K8s scripts)
│       ├── provision-machine.sh (Main provisioning)
│       ├── k8s-control-plane-init.sh (Kubernetes setup)
│       ├── device-passthrough.sh (Hardware configuration)
│       └── manage-cluster.sh (Cluster management)
└── State API Server (Python, port 8080)
    └── SQLite database (/srv/state/machines.db)

Kubernetes Control Plane Cluster
├── First Master (k8s-cp-1)
│   ├── kubeadm init (cluster bootstrap)
│   ├── Calico CNI installation
│   └── etcd cluster initialization
├── Additional Masters (k8s-cp-2, k8s-cp-3)
│   ├── kubeadm join --control-plane
│   └── etcd cluster members
└── Device Passthrough
    ├── GPU nodes (NVIDIA drivers + container toolkit)
    ├── NFS nodes (shared storage + storage classes)
    └── Storage nodes (local storage + CSI drivers)
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

## Kubernetes Control Plane Management

The system provides comprehensive Kubernetes control plane management through several specialized scripts:

### Cluster Initialization

The `k8s-control-plane-init.sh` script handles:

- **First Master Bootstrap**: Initializes the cluster with kubeadm
- **Additional Masters**: Joins additional control plane nodes for HA
- **CNI Installation**: Deploys Calico networking with custom configuration
- **Node Labeling**: Applies appropriate labels based on machine features
- **Storage Classes**: Creates NFS and local storage classes
- **Cluster Validation**: Verifies cluster health and component status

### Device Passthrough Configuration

The `device-passthrough.sh` script configures:

- **GPU Support**: NVIDIA drivers, container toolkit, and runtime configuration
- **NFS Server**: Shared storage with automatic exports and storage classes
- **Storage Systems**: Local storage provisioning and CSI driver setup
- **Device Detection**: Automatic hardware detection and feature enablement
- **Monitoring**: Device status monitoring and alerting

### Cluster Management

Use `manage-cluster.sh` for ongoing cluster operations:

```bash
# Check cluster status
./manage-cluster.sh status

# Show detailed node information
./manage-cluster.sh nodes

# Generate join commands for new nodes
./manage-cluster.sh join-command control-plane
./manage-cluster.sh join-command worker

# Backup cluster configuration
./manage-cluster.sh backup

# Restore from backup
./manage-cluster.sh restore /path/to/backup

# Drain node for maintenance
./manage-cluster.sh drain-node k8s-worker-1

# Show device passthrough status
./manage-cluster.sh device-status
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
- **gpu**: Install NVIDIA drivers and container toolkit for AI workloads
- **nfs**: Set up NFS server for shared storage across the cluster
- **storage**: Configure additional storage systems (local storage, CSI drivers)
- **compute**: General compute node configuration
- **inference**: Specialized GPU nodes for ML inference workloads
- **monitoring**: Prometheus, Grafana, and cluster monitoring tools

### Supported Roles

- **control-plane**: Kubernetes master node with etcd, API server, scheduler
- **worker**: Kubernetes worker node (to be managed by Kubespray in the future)
- **compute**: General compute node for non-Kubernetes workloads

### Control Plane Specific Configuration

Control plane nodes get additional configuration:

- **etcd**: Clustered etcd setup for high availability
- **Load Balancer**: HAProxy for API server load balancing (if multiple masters)
- **Cluster Networking**: Calico CNI with custom pod and service CIDRs
- **Storage Classes**: Automatic creation of NFS and local storage classes
- **Node Taints**: Proper tainting for control plane nodes
- **Certificates**: Automatic certificate management and rotation

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

### Standard PXE Boot Process

1. **PXE Boot**: Machine boots from network and loads Debian installer
2. **Preseed Installation**: Automated Debian installation using preseed configuration
3. **Machine Identification**: System identifies itself by MAC address
4. **Configuration Retrieval**: Downloads machine-specific configuration from API
5. **Feature Provisioning**: Installs and configures features based on machine role
6. **State Reporting**: Reports provisioning progress and final state
7. **Ready**: Machine is ready for use with persistent state maintained

### Kubernetes Control Plane Boot Process

For control plane nodes, additional steps are executed:

8. **Device Passthrough**: Configure GPU, NFS, and storage based on machine features
9. **Kubernetes Installation**: Install kubeadm, kubelet, kubectl, and container runtime
10. **Cluster State Check**: Determine if this is the first master or joining existing cluster
11. **Cluster Initialization**:
    - **First Master**: Bootstrap cluster with kubeadm init
    - **Additional Masters**: Join existing cluster with kubeadm join --control-plane
12. **CNI Installation**: Deploy Calico networking with cluster-specific configuration
13. **Storage Configuration**: Create storage classes for NFS and local storage
14. **Node Configuration**: Apply labels, taints, and feature-specific settings
15. **Cluster Validation**: Verify all components are healthy and operational
16. **State Persistence**: Save cluster join tokens and configuration for future nodes

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
│       ├── provision-machine.sh   # Main provisioning script
│       ├── k8s-control-plane-init.sh  # Kubernetes initialization
│       ├── device-passthrough.sh  # Hardware configuration
│       ├── manage-cluster.sh      # Cluster management tools
│       ├── machine-state.sh       # State management utilities
│       └── state-api.py           # State management API server
└── state/                         # State database and cluster data
    ├── machines.db                # SQLite database
    ├── cluster/                   # Kubernetes cluster state
    │   ├── join-tokens.yaml       # Join tokens for new nodes
    │   ├── cluster-config.yaml    # Cluster configuration
    │   └── certificates/          # Cluster certificates backup
    └── backups/                   # Cluster backup storage

Local Scripts (in this directory):
├── control-plane-boot.sh          # Main PXE server setup
├── k8s-control-plane-init.sh      # Kubernetes control plane setup
├── device-passthrough.sh          # Device configuration script
├── manage-cluster.sh              # Cluster management script
├── manage-machines.sh             # Machine registry management
├── monitor-machines.sh            # Machine monitoring dashboard
└── README.md                      # This documentation
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

### Kubernetes Troubleshooting

#### Check cluster status:

```bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl cluster-info
```

#### Check control plane components:

```bash
kubectl get pods -n kube-system
sudo systemctl status kubelet
sudo journalctl -u kubelet -f
```

#### Verify networking:

```bash
kubectl get pods -n calico-system
kubectl get caliconodes
```

#### Check device passthrough:

```bash
# GPU nodes
nvidia-smi
kubectl get nodes -l feature.node.kubernetes.io/gpu=nvidia
docker run --rm --gpus all nvidia/cuda:11.0-base nvidia-smi

# NFS nodes
showmount -e localhost
kubectl get storageclass
kubectl get pv

# Storage nodes
lsblk
kubectl get nodes -l feature.node.kubernetes.io/storage=available
```

#### Reset cluster (emergency):

```bash
# On control plane nodes
sudo kubeadm reset
sudo rm -rf /etc/kubernetes/
sudo rm -rf /var/lib/etcd/
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X
```

#### Re-run initialization:

```bash
# Download and run initialization script
wget http://10.0.0.10/scripts/k8s-control-plane-init.sh
chmod +x k8s-control-plane-init.sh
sudo ./k8s-control-plane-init.sh
```

## Security Considerations

### Infrastructure Security

- Change default passwords in preseed configuration
- Configure firewall rules for PXE services
- Use HTTPS for production deployments
- Implement authentication for API endpoints
- Regular backup of machine registry and state database

### Kubernetes Security

- **Certificate Management**: Automatic certificate rotation is enabled
- **RBAC**: Default RBAC policies are applied during cluster initialization
- **Network Policies**: Calico network policies can be applied for micro-segmentation
- **Pod Security Standards**: Consider enabling Pod Security Standards for workload security
- **Secrets Management**: Store sensitive data in Kubernetes secrets, not in the registry
- **etcd Security**: etcd is configured with TLS encryption for cluster communication
- **API Server Security**: API server is configured with appropriate security flags

### Device Passthrough Security

- **GPU Security**: NVIDIA container toolkit is configured with proper isolation
- **NFS Security**: NFS exports are configured with appropriate access controls
- **Storage Security**: Storage devices are properly mounted with secure permissions

## Next Steps

1. **Configure Machine Registry**: Update `/srv/http/machines/registry.json` with your actual machine MAC addresses and specifications
2. **Test Provisioning**: Boot your first control plane node and monitor the process
3. **Validate Cluster**: Ensure the first control plane node initializes correctly
4. **Add Additional Masters**: Boot additional control plane nodes for high availability
5. **Configure Monitoring**: Set up cluster monitoring and alerting
6. **Worker Nodes**: Future implementation will use Kubespray for worker node provisioning

For worker node provisioning using Kubespray, see `/home/skinner/homelab/provisioning/worker-nodes/README.md`.

## Remote Deployment

The control plane scripts are designed to be executed on remote servers via SSH. Two deployment methods are available:

### Method 1: Using the Remote Deployment Wrapper (Recommended)

The `remote-deploy.sh` script provides a convenient way to upload and execute scripts on remote hosts:

```bash
# Set up SSH keys (first time only)
./ssh-helper.sh setup-keys netboot@10.0.0.2

# Deploy and run control plane boot script
./remote-deploy.sh control-plane-boot

# Deploy and run Kubernetes control plane initialization
./remote-deploy.sh k8s-control-plane

# Check remote host status
./remote-deploy.sh status

# View logs from remote host
./remote-deploy.sh logs
```

### Method 2: Direct SSH Execution

For direct execution without the wrapper:

```bash
# Simple one-liner (for scripts that don't need persistence)
ssh netboot@10.0.0.2 'bash -s' < ~/homelab/provisioning/control-plane/control-plane-boot.sh

# For scripts that need to be present on the remote host
scp ~/homelab/provisioning/control-plane/*.sh netboot@10.0.0.2:/tmp/
ssh netboot@10.0.0.2 'cd /tmp && sudo bash control-plane-boot.sh'
```

### SSH Setup

Use the SSH helper to configure connectivity:

```bash
# Test SSH connection
./ssh-helper.sh test-connection netboot@10.0.0.2

# Set up SSH keys for passwordless authentication
./ssh-helper.sh setup-keys netboot@10.0.0.2

# Add host to known_hosts
./ssh-helper.sh add-host netboot@10.0.0.2
```
