# Homelab

Infrastructure as Code for a K3s cluster running on Raspberry Pi 5 nodes.

## Cluster

| Node | Role | Architecture | RAM |
|------|------|-------------|-----|
| `k3s-arm-node-0` | Control Plane | ARM64 | 8GB |
| Worker 1–4 | Worker | ARM64 | 8GB each |

- **Runtime**: K3s
- **Storage**: Longhorn (`longhorn-nvme`)
- **Ingress**: Traefik (K3s default) — will be replaced by Istio for Kubeflow

## Applications

- **[n8n](n8n/)** — Workflow automation platform with PostgreSQL backend

---

## Kubeflow Roadmap

Deploy the full Kubeflow ML platform on an all-ARM64 Raspberry Pi 5 cluster using Kustomize.

### Constraints

| Constraint | Impact | Mitigation |
|---|---|---|
| ARM64-only cluster | Most Kubeflow images lack ARM64 builds | QEMU binfmt_misc emulation; native ARM64 images where available |
| 32GB total worker RAM | Full Kubeflow + Istio needs ~12–16GB for platform components | Tune resource requests down; phased deployment |
| No GPUs | ML training limited to CPU (+ Coral TPU for edge inference) | Focus on lightweight models and pipeline orchestration |

### Phase 0: Prerequisites & Cluster Preparation

- [ ] **QEMU user-mode emulation** — Deploy a DaemonSet on all workers to register binfmt handlers, enabling AMD64 containers on ARM64 nodes
- [ ] **Disable Traefik** — Reconfigure K3s to remove the built-in Traefik ingress (`/etc/rancher/k3s/config.yaml` → `disable: traefik`)
- [ ] **cert-manager** — Install for webhook certificate management (ARM64 images available)
- [ ] **Istio** — Install Istio 1.20+ with ARM64 images and Kubeflow-recommended profile; replaces Traefik as cluster ingress
- [ ] **Dex** — Identity provider for Kubeflow authentication with static user credentials

### Phase 1: Kubeflow Core

- [ ] **Kubeflow manifests** — Clone `kubeflow/manifests` repo at latest stable tag; Kustomize overlays for all components
- [ ] **Central Dashboard** — Kubeflow web UI exposed via Istio IngressGateway
- [ ] **Profiles Controller** — Per-user namespace and resource quota management
- [ ] **Admission Webhook** — PodDefaults injection for configuration management
- [ ] **Verify** — Dashboard accessible, Dex login works, profile creation succeeds

### Phase 2: Kubeflow Pipelines

- [ ] **Argo Workflows** — Pipeline execution engine (ARM64 images available)
- [ ] **MinIO** — Artifact storage on `longhorn-nvme` PVCs (ARM64 images available)
- [ ] **Pipeline components** — API server, persistence agent, scheduler, UI, metadata services
- [ ] **Verify** — Create and execute a simple pipeline, confirm artifact storage

### Phase 3: Notebook Servers

- [ ] **Notebook Controller** — Jupyter server lifecycle management
- [ ] **ARM64 notebook images** — Configure `jupyter/minimal-notebook` and `jupyter/scipy-notebook` (native ARM64)
- [ ] **Volumes Web App** — PVC management UI from the dashboard
- [ ] **Verify** — Spin up a notebook server, run Python code

### Phase 4: Training & Experimentation *(optional — resource permitting)*

- [ ] **Training Operator** — Distributed training jobs (TFJob, PyTorchJob)
- [ ] **Katib** — Hyperparameter tuning and neural architecture search
- [ ] **Verify** — Submit a training job, run a Katib experiment

### Phase 5: Model Serving *(optional — resource permitting)*

- [ ] **Knative Serving** — Required by KServe (additional resource overhead)
- [ ] **KServe** — Model serving controller
- [ ] **Verify** — Deploy a model and send inference requests

### Target Directory Structure

```
kubeflow/
├── README.md
├── deploy.sh
├── prerequisites/
│   ├── qemu-binfmt-daemonset.yaml
│   ├── cert-manager/
│   │   └── kustomization.yaml
│   ├── istio/
│   │   └── kustomization.yaml
│   └── dex/
│       └── kustomization.yaml
├── core/
│   ├── kustomization.yaml
│   └── namespace.yaml
├── pipelines/
│   ├── kustomization.yaml
│   └── minio-pvc.yaml
├── notebooks/
│   ├── kustomization.yaml
│   └── notebook-images-config.yaml
├── training/
│   └── kustomization.yaml
└── serving/
    └── kustomization.yaml
```

### Key Decisions

- **QEMU over building from source** — Building ARM64 images for all Kubeflow components is a massive maintenance burden. QEMU emulation is acceptable for learning/exploration despite ~5–10x overhead on emulated containers.
- **Replace Traefik with Istio** — Kubeflow requires Istio for auth, routing, and KServe. Istio becomes the cluster-wide ingress and service mesh.
- **Phased deployment** — Manages the 32GB RAM constraint and surfaces ARM64 compatibility issues incrementally.
- **Phases 4–5 are optional** — 32GB may not support Training Operator + Katib + KServe/Knative on top of the core platform.
- **Image audit before each phase** — Run `docker manifest inspect` on each required image to check ARM64 availability. Native ARM64 images skip QEMU and run at full speed.