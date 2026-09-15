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

All five models use the internal `inference/ollama` service. Cloud backends are
registered in Agent Router but intentionally excluded from these automatic
decisions until they pass the remote quality and availability gates. The
Ollama host must support the current Gemma 4 manifest; Ollama 0.16.1 is too
old.

The v0.3.0 image does not support the newer `input_modality` signal, so the
current multimodal lane uses validated keyword rules. Upgrade and validate the
router image before enabling structural modality signals.

The deployment runs two replicas with a PodDisruptionBudget. Its install
wrapper uses a no-surge rolling strategy because this cluster cannot schedule a
temporary third router pod during upgrades.

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
