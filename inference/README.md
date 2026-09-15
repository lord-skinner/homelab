# Inference provider

The `ollama` Service provides in-cluster access to the Ollama instance running
on `skinnerdev`, which has an NVIDIA GeForce RTX 3080 Ti. The GPU host is not a
Kubernetes node.

Apply the provider endpoint with:

```sh
kubectl apply -f inference/namespace.yaml
kubectl apply -f inference/ollama-service.yaml
```

Workloads can use:

```text
http://ollama.inference.svc.cluster.local:11434
```

Installed models:

- `qwen3:14b` — general reasoning
- `qwen2.5-coder:14b` — coding
- `deepseek-r1:14b` — reasoning
- `phi4:14b` — general-purpose text
- `gemma4:latest` — multimodal text and image input

These are Q4 quantizations sized for the host's 12 GB RTX 3080 Ti. They fit
individually; Ollama should be treated as a single-model-at-a-time provider on
this GPU.

The Ollama API is unauthenticated on the private network. Keep this Service
internal to the cluster unless an authenticated gateway is added.

The EndpointSlice currently points at `192.168.0.254`, the LAN address of
`skinnerdev`. Update it if the host's address changes.

The Ollama host runs Ollama 0.34.0. After upgrading the host, the replacement
model was installed with:

```sh
ollama pull gemma4:latest
ollama list
```

After the replacement is verified through the gateway, the old model can be
removed with `ollama rm gemma3:12b`.
