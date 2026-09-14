# Homelab

Infrastructure as Code for a K3s cluster running on Raspberry Pi 5 nodes.

## Cluster

| Node | Role | Architecture | RAM |
|------|------|-------------|-----|
| `k3s-arm-node-0` | Control Plane | ARM64 | 8GB |
| Worker 1–4 | Worker | ARM64 | 8GB each |

- **Runtime**: K3s
- **Storage**: local-path (K3s default)
- **Ingress**: Traefik (K3s default)

## Applications

- **[n8n](n8n/)** — Workflow automation platform with PostgreSQL backend
- **[nextcloud](nextcloud/)** — Private file sync and collaboration service at `nas.home.datalab.gg`, backed by MariaDB, Redis, and a persistent volume
- **[elastic](elastic/)** — Elasticsearch, Kibana, and Elastic Agent observability stack at `es.home.datalab.gg`

## Operations

- **[Cluster health and rollout verification](docs/cluster-health.md)** — non-mutating checks for nodes, workloads, storage, Prometheus, ingress backends, TLS smoke endpoints, restarts, and recurring error logs.
