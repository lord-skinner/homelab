# vLLM Semantic Router

This release runs the vLLM Semantic Router ExtProc alongside Agent Router. It
is attached only to the `home-ingress` HTTPS listener through an
`EnvoyPatchPolicy`; the HTTP redirect listener and application paths remain
unchanged.

The initial policy is local-only and uses keyword decisions:

- coding/infrastructure → `qwen2.5-coder:14b`
- math → `phi4:14b`
- explicit complex reasoning → `deepseek-r1:14b`
- image/document/translation requests → `gemma4:latest`
- default → `qwen3:14b`

All five models use the internal `inference/ollama` service. Cloud backends and
failover are intentionally not configured yet. The Ollama host must support
the current Gemma 4 manifest; Ollama 0.16.1 is too old.

Semantic Router tracing is disabled because this cluster does not run a Jaeger
collector. Prometheus metrics remain enabled.

Install the router:

```sh
./infrastructure/semantic-router/install-semantic-router.sh
```

Attach it to Envoy after the deployment is ready:

```sh
kubectl apply -f infrastructure/semantic-router/envoypatchpolicy.yaml
```

Clients request automatic routing with `"model": "auto"` at
`https://llm.home.datalab.gg/v1/chat/completions`. Explicit physical model
names continue to work through the existing Agent Router route.
