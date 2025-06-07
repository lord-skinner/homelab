# Network Boot Server Setup for Kubernetes Cluster

This directory contains scripts and configuration for setting up a Raspberry Pi 3 as a network boot server for a mixed architecture (ARM and AMD) Kubernetes cluster.

## Overview

The setup script configures a Raspberry Pi 3 with the following services:

1. **DHCP Server**: Assigns IP addresses and provides boot information to nodes
2. **TFTP Server**: Serves boot files (kernels, initrd, bootloaders)
3. **NFS Server**: Provides root filesystems for diskless nodes

## Prerequisites

- A Raspberry Pi 3 with a fresh OS installation (Raspberry Pi OS / Raspbian recommended)
- Stable network connection (wired Ethernet recommended)
- Sufficient storage attached to the Raspberry Pi for hosting root filesystems
- Client machines configured to support network booting (PXE/UEFI network boot enabled in BIOS)

## Setup Instructions

1. Clone this repository to your Raspberry Pi 3
2. Review and modify the network configuration in `setup-netboot.sh` to match your network setup
3. Make the script executable: `chmod +x setup-netboot.sh`
4. Run the script as root: `sudo ./setup-netboot.sh`
5. Follow the on-screen instructions to complete the setup

## Directory Structure

After running the setup script, the following directory structure will be created:

```
/srv/netboot/
├── tftp/                  # TFTP boot files
│   ├── pxelinux.cfg/      # PXE boot configurations
│   ├── arm/               # ARM boot files
│   └── amd/               # AMD boot files
└── nfs/                   # NFS root filesystems
    ├── arm/               # ARM root filesystems
    └── amd/               # AMD root filesystems
```

## Adding Boot Files

### For ARM Nodes (Raspberry Pi, etc.)

Place the following files in `/srv/netboot/tftp/arm/`:

- `vmlinuz`: The Linux kernel for ARM64
- `initrd.img`: Initial RAM disk
- `u-boot.bin`: U-Boot binary for ARM64 systems

For Raspberry Pi nodes specifically, you may need to include additional firmware files.

### For AMD Nodes (x86_64)

Place the following files in `/srv/netboot/tftp/amd/`:

- `vmlinuz`: The Linux kernel for x86_64
- `initrd.img`: Initial RAM disk
- For UEFI boot: Place GRUB EFI files in the `/srv/netboot/tftp/amd/grub2/` directory

## Preparing Root Filesystems

You need to prepare root filesystems for each architecture:

### Method 1: Using an existing system as a template

For ARM64:

```bash
sudo rsync -axHAWX --numeric-ids --info=progress2 --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found"} / /srv/netboot/nfs/arm/base/
```

For AMD64:

```bash
sudo rsync -axHAWX --numeric-ids --info=progress2 --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found"} / /srv/netboot/nfs/amd/base/
```

### Method 2: Using debootstrap (for Debian-based systems)

For ARM64:

```bash
sudo debootstrap --arch=arm64 bullseye /srv/netboot/nfs/arm/base http://deb.debian.org/debian
```

For AMD64:

```bash
sudo debootstrap --arch=amd64 bullseye /srv/netboot/nfs/amd/base http://deb.debian.org/debian
```

## Adding Nodes to the Cluster

Use the helper script to add new nodes to your cluster:

```bash
sudo /srv/netboot/add-node.sh <node_name> <mac_address> <ip_address> <architecture>
```

Example:

```bash
sudo /srv/netboot/add-node.sh worker1 00:11:22:33:44:55 192.168.1.101 amd
```

## Troubleshooting

### DHCP Issues

- Check if the DHCP server is running: `systemctl status isc-dhcp-server`
- Check DHCP logs: `journalctl -u isc-dhcp-server`
- Ensure there are no IP conflicts on your network

### TFTP Issues

- Check if dnsmasq is running: `systemctl status dnsmasq`
- Check TFTP logs: `journalctl -u dnsmasq`
- Verify file permissions in the TFTP directory

### NFS Issues

- Check if NFS server is running: `systemctl status nfs-kernel-server`
- Check NFS exports: `exportfs -v`
- Verify NFS mounts on client: `mount | grep nfs`

## Additional Resources

- [PXE Boot Documentation](https://wiki.debian.org/PXEBootInstall)
- [NFS Root Documentation](https://wiki.debian.org/NFSServerSetup)
- [U-Boot Documentation](https://www.denx.de/wiki/U-Boot)
- [GRUB Network Boot](https://www.gnu.org/software/grub/manual/grub/html_node/Network.html)

## Node-Specific Configurations

For specific node configurations, create separate directories in the NFS root filesystem. For example:

```
/srv/netboot/nfs/arm/worker-a1/
/srv/netboot/nfs/amd/worker-x1/
```

Then modify the PXE boot configuration to point to the specific root filesystem for each node.
