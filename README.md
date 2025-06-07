# homelab
Code base for my homelab setup

### Details Table

| Node         | Description        | Hardware                       | Other       | Notes               |
|--------------|--------------------|--------------------------------|-------------|---------------------|
| tftp         | Raspberry PI 3b+   | 4 cores, 4 threads, 1GB RAM    |             | Network Boots       |
| master (amd) | Custom AMD Build   | 4 cores, 4 threads, 16GB RAM   | 20TB Raid   | master + NFS        |
| amd-node-1   | Custom AMD Build   | 12 cores, 24 threads, 64GB RAM | 20GB VRAM   | Inference Node      |
| amd-node-2   | Custom Intel Build | 14 cores, 20 threads, 32GB RAM |             | AMD64 Compute Node  |
| arm-node-1   | Raspberry PI 5     | 4 cores, 4 threads, 8GB RAM    | 4 TPU Cores | ARM64 Compute Node  |
| arm-node-2   | Raspberry PI 5     | 4 cores, 4 threads, 8GB RAM    |             | ARM64 Compute Node  |
| arm-node-3   | Raspberry PI 5     | 4 cores, 4 threads, 8GB RAM    |             | ARM64 Compute Node  |
| arm-node-4   | Raspberry PI 5     | 4 cores, 4 threads, 8GB RAM    |             | ARM64 Compute Node  |
| arm-node-5   | Raspberry PI 5     | 4 cores, 4 threads, 8GB RAM    |             | ARM64 Compute Node  |
| arm-node-6   | Raspberry PI 5     | 4 cores, 4 threads, 8GB RAM    |             | ARM64 Compute Node  |


| Cluster Totals |
|----------------|
| 9 Nodes        |
| 54 Cores       |
| 72 Threads     |
| 160 GB RAM     |
| 20TB Storage   |
| 20GB VRAM      |
| 4 Tensor Cores |


| Cluster Features       |
|------------------------|
| Network Boots          |
| Multi Architecture     |
| Automated Provisioning |
| More to Come...        |