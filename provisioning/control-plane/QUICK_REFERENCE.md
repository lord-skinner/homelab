# Kubernetes Control Plane Auto-Provisioning Quick Reference

## 🚀 Quick Start

1. **Validate Setup**

   ```bash
   ./validate-setup.sh
   ```

2. **Setup PXE Server** (run as root)

   ```bash
   sudo ./control-plane-boot.sh
   ```

3. **Update Machine Registry**

   ```bash
   sudo nano /srv/http/machines/registry.json
   ```

4. **Monitor Provisioning**
   ```bash
   ./monitor-machines.sh
   ```

## 📝 Machine Registry Template

Replace MAC addresses with your actual hardware:

```json
{
  "machines": {
    "YOUR:MAC:ADDRESS:HERE": {
      "hostname": "k8s-cp-1",
      "role": "control-plane",
      "architecture": "amd64",
      "features": ["kubernetes", "nfs", "storage"],
      "ip": "10.0.0.11"
    }
  }
}
```

## 🛠️ Management Commands

### Machine Management

```bash
./manage-machines.sh list                    # List all machines
./manage-machines.sh status                  # Check machine status
./manage-machines.sh add MAC HOST ROLE ARCH FEATURES
```

### Cluster Management

```bash
./manage-cluster.sh status                   # Cluster status
./manage-cluster.sh nodes                    # Node information
./manage-cluster.sh join-command control-plane  # Get join command
./manage-cluster.sh backup                   # Backup cluster
```

### Monitoring

```bash
./monitor-machines.sh                        # Real-time dashboard
./monitor-machines.sh --once                 # One-time check
```

## 🔧 Network Configuration

- **DHCP Range**: 10.0.0.200 - 10.0.0.209 (for PXE boot)
- **PXE Server**: 10.0.0.10
- **Control Plane IPs**: 10.0.0.11+ (static, defined in registry)

## 🔍 Troubleshooting

### Check Services

```bash
sudo systemctl status tftpd-hpa isc-dhcp-server nginx machine-state-api
```

### Check Logs

```bash
sudo journalctl -u machine-state-api -f
curl http://10.0.0.10:8080/api/states
```

### Kubernetes Issues

```bash
kubectl get nodes -o wide
kubectl get pods -A
sudo journalctl -u kubelet -f
```

## 📁 Important Files

- `/srv/http/machines/registry.json` - Machine configurations
- `/srv/state/machines.db` - Machine state database
- `/srv/state/cluster/` - Kubernetes cluster state
- `/var/log/syslog` - System logs

## 🎯 Boot Process Flow

1. **PXE Boot** → Machine network boots
2. **Debian Install** → Automated OS installation
3. **Provisioning** → Role-based configuration
4. **K8s Setup** → Cluster initialization
5. **Device Config** → GPU/NFS/Storage setup
6. **Ready** → Node joins cluster

## ⚠️ Prerequisites

- Machines configured for PXE boot
- Network allows DHCP/TFTP traffic
- Internet connectivity for package downloads
- Root access on PXE server

For detailed documentation, see `README.md`
