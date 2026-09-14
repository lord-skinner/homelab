# Agent Router and local Ollama models

This directory installs Agent Router (formerly Envoy AI Gateway) and registers
the Ollama models reachable through the internal `inference/ollama` Service.
Agent Router generates the Envoy Gateway route and uses the `x-ai-eg-model`
request header to select a model.

The current local model catalog is:

- `qwen3:14b`
- `qwen2.5-coder:14b`
- `deepseek-r1:14b`
- `phi4:14b`
- `gemma3:12b`

Install or reconcile the controller and its Envoy Gateway integration:

```sh
./infrastructure/agent-router/install-agent-router.sh
```

Apply the local model backends and route:

```sh
./infrastructure/agent-router/apply-ollama-models.sh
```

The route is intentionally limited to the five local models. There is no cloud
fallback yet. A future change can add cloud `AIServiceBackend` resources and
ordered backend selection, followed by vLLM Semantic Router as an Envoy
External Processing decision layer for local-first/task-aware routing.

A direct smoke request through the existing Gateway is:

```sh
curl --fail --silent --show-error --max-time 180 \
  -H 'Content-Type: application/json' \
  -H 'x-ai-eg-model: qwen3:14b' \
  -d '{"model":"qwen3:14b","messages":[{"role":"user","content":"Reply with exactly: AI gateway test"}],"stream":false,"max_tokens":16}' \
  https://llm.home.datalab.gg/v1/chat/completions
```

The AI route uses `llm.home.datalab.gg` on the existing wildcard certificate.
The model header is required so requests for an unregistered model receive the
Agent Router route-not-found response. Ollama remains cluster-internal; only
the Gateway is Tailscale-exposed.
