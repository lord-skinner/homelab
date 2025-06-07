# homelab

Code base for my homelab setup

## Homelab Details

| Resrouce | Device           | Hardware                    | Notes                            |
| -------- | ---------------- | --------------------------- | -------------------------------- |
| tftp     | Raspberry PI 3b+ | 4 cores, 4 threads, 1GB RAM | Network Boots & root filesystems |
| dhcp     | Unifi w/ VLAN    | Unifi Dream Router          | Homelab Network VLAN 10.0.0.10   |

### Cluster Details

| Node         | Description        | Hardware                       | Other       | Notes              |
| ------------ | ------------------ | ------------------------------ | ----------- | ------------------ |
| master (amd) | Custom AMD Build   | 4 cores, 4 threads, 16GB RAM   | 20TB Raid   | master + NFS       |
| amd-node-1   | Custom AMD Build   | 12 cores, 24 threads, 64GB RAM | 20GB VRAM   | Inference Node     |
| amd-node-2   | Custom Intel Build | 14 cores, 20 threads, 32GB RAM |             | AMD64 Compute Node |
| arm-node-1   | Raspberry PI 5     | 4 cores, 4 threads, 8GB RAM    | 4 TPU Cores | ARM64 Compute Node |
| arm-node-2   | Raspberry PI 5     | 4 cores, 4 threads, 8GB RAM    |             | ARM64 Compute Node |
| arm-node-3   | Raspberry PI 5     | 4 cores, 4 threads, 8GB RAM    |             | ARM64 Compute Node |
| arm-node-4   | Raspberry PI 5     | 4 cores, 4 threads, 8GB RAM    |             | ARM64 Compute Node |
| arm-node-5   | Raspberry PI 5     | 4 cores, 4 threads, 8GB RAM    |             | ARM64 Compute Node |
| arm-node-6   | Raspberry PI 5     | 4 cores, 4 threads, 8GB RAM    |             | ARM64 Compute Node |

| Cluster Totals |
| -------------- |
| 9 Nodes        |
| 54 Cores       |
| 72 Threads     |
| 160 GB RAM     |
| 20TB Storage   |
| 20GB VRAM      |
| 4 Tensor Cores |

| Cluster Features       |
| ---------------------- |
| Network Boots          |
| Multi Architecture     |
| Automated Provisioning |
| More to Come...        |


## NETBOOT Diagram
```
                                  ┌─────────────────┐
                                  │                 │
                                  │  Raspberry Pi 3 │
                                  │  Network Boot   │
                                  │  Server         │
                                  │                 │
                                  └─────┬───────────┘
                                        │
                                        │ Ethernet
                                        │
                     ┌─────────────────┴──────────────────┐
                     │                                    │
                     │           Network Switch           │
                     │                                    │
                     └───┬─────────────┬──────────┬───────┘
                         │             │          │
                         │             │          │
               ┌─────────┴──────┐      │      ┌───┴──────────────┐
               │                │      │      │                  │
               │  AMD64 Node    │      │      │  ARM64 Node      │
               │(Control Plane) │      │      │  (Worker)        │
               │                │      │      │                  │
               └────────────────┘      │      └──────────────────┘
                                       │
                               ┌───────┴──────────┐
                               │                  │
                               │  AMD64 Node      │
                               │  (Worker)        │
                               │                  │
                               └──────────────────┘

Services running on Raspberry Pi 3:
┌───────────────────────────────────────────────────────────┐
│                                                           │
│  ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐ │
│  │  DHCP   │    │  TFTP   │    │  NFS    │    │ Helper  │ │
│  │ Server  │    │ Server  │    │ Server  │    │ Scripts │ │
│  └─────────┘    └─────────┘    └─────────┘    └─────────┘ │
│                                                           │
└───────────────────────────────────────────────────────────┘

Directory Structure:
/srv/netboot/
├── tftp/                  # TFTP boot files
│   ├── pxelinux.cfg/      # PXE boot configurations
│   ├── arm/               # ARM boot files
│   └── amd/               # AMD boot files
└── nfs/                   # NFS root filesystems
    ├── arm/               # ARM root filesystems
    │   └── worker1/       # Worker node filesystem
    └── amd/               # AMD root filesystems
        ├── master1/       # Control plane node filesystem
        └── worker2/       # Worker node filesystem

Network Boot Process:
1. Node powers on and broadcasts DHCP request
2. Raspberry Pi responds with IP and boot file information
3. Node downloads boot files via TFTP
4. Node mounts root filesystem via NFS
5. Node boots and joins Kubernetes cluster
```
