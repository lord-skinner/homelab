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
- `gemma4:latest`

Install or reconcile the controller and its Envoy Gateway integration:

```sh
./infrastructure/agent-router/install-agent-router.sh
```

Apply the local model backends and route:

```sh
./infrastructure/agent-router/apply-ollama-models.sh
```

The five local models remain the automatic default. Cloud models are registered
as explicit Agent Router routes, while vLLM Semantic Router keeps them outside
automatic selection until their quality and availability gates are met.

## OpenRouter free models

The separate OpenRouter catalog adds direct, explicitly selected cloud routes
without changing Semantic Router fallbacks:

- `cohere/north-mini-code:free` — code-focused text model
- `google/gemma-4-26b-a4b-it:free` — multimodal text/image/video model
- `nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free` — multimodal reasoning model
- `inclusionai/ling-3.0-flash-vl:free` — vision-language model
- `nex-agi/nex-n2.5-pro:free` — visual coding-agent candidate
- `liquid/lfm-2.5-2.6b:free` — extraction/RAG efficiency candidate

The catalog was selected from OpenRouter's zero-price model list on 2026-09-14;
free model availability and provider rate limits can change. The API key is
not stored in Git. Reconcile the Secret and backends with:

```sh
export OPENROUTER_API_KEY='...'
./infrastructure/agent-router/apply-openrouter-models.sh
```

The script creates the `inference/openrouter-api-key` Secret, configures HTTPS
to `openrouter.ai`, and applies the provider-specific Gateway routes. Clients
can select a provider explicitly with `x-ai-eg-model`; automatic `model: auto`
routing remains local-only until cloud fallback policy is deliberately enabled
and qualified.

### Complete free-model catalog

The following models were returned by OpenRouter's model API with both prompt
and completion pricing equal to zero on 2026-09-14. This is an inventory for
future routing; it does not mean every model below has a configured Gateway
backend.

| Model ID | Name | Input/output modality | Context |
|---|---|---|---:|
| `cohere/north-mini-code:free` | Cohere: North Mini Code | text → text | 256K |
| `dots-studio/dots-3-note-preview:free` | Dots Studio: Dots3-Note Preview | text + image → text | 512K |
| `google/gemma-4-26b-a4b-it:free` | Google: Gemma 4 26B A4B | text + image + video → text | 256K |
| `google/gemma-4-31b-it:free` | Google: Gemma 4 31B | text + image + video → text | 256K |
| `google/lyria-3-clip-preview` | Google: Lyria 3 Clip Preview | text + image → text + audio | 1M |
| `google/lyria-3-pro-preview` | Google: Lyria 3 Pro Preview | text + image → text + audio | 1M |
| `inclusionai/ling-3.0-flash-fin:free` | inclusionAI: Ling 3.0 Flash Fin | text → text | 256K |
| `inclusionai/ling-3.0-flash-sante:free` | inclusionAI: Ling 3.0 Flash Sante | text → text | 256K |
| `inclusionai/ling-3.0-flash-vl:free` | inclusionAI: Ling 3.0 Flash VL | text + image + video → text | 256K |
| `liquid/lfm-2.5-2.6b:free` | LiquidAI: LFM2.5-2.6B | text → text | 64K |
| `nex-agi/nex-n2.5-mini:free` | Nex AGI: Nex-N2.5-Mini | text + image → text | 256K |
| `nex-agi/nex-n2.5-pro:free` | Nex AGI: Nex-N2.5-Pro | text + image → text | 256K |
| `nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free` | NVIDIA: Nemotron 3 Nano Omni | text + image + audio + video → text | 256K |
| `nvidia/nemotron-3-super-120b-a12b:free` | NVIDIA: Nemotron 3 Super | text → text | 256K |
| `nvidia/nemotron-3-ultra-550b-a55b:free` | NVIDIA: Nemotron 3 Ultra | text → text | 1M |
| `nvidia/nemotron-3.5-content-safety:free` | NVIDIA: Nemotron 3.5 Content Safety | text + image → text | 128K |
| `nvidia/nemotron-3.5-lightning:free` | NVIDIA: Nemotron 3.5 Lightning | text → text | 1M |
| `openrouter/free` | OpenRouter Free Models Router | text + image → text | 200K |
| `poolside/laguna-s-2.1:free` | Poolside: Laguna S 2.1 | text → text | 256K |
| `poolside/laguna-xs-2.1:free` | Poolside: Laguna XS 2.1 | text → text | 256K |
| `thinkingmachines/inkling-small:free` | Thinking Machines: Inkling Small | text + image + audio → text | 1M |
| `thinkingmachines/inkling:free` | Thinking Machines: Inkling | text + image + audio → text | 1M |

Observed smoke tests:

- Cohere code route: HTTP 200, response model matched
  `cohere/north-mini-code:free`.
- Google Gemma route: HTTP 429 from the upstream shared free pool.
- NVIDIA Nemotron route: HTTP 502 because the provider reported its shared
  worker limit was exhausted.

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

See [openrouter-model-evaluation.md](openrouter-model-evaluation.md) for the
full live inventory, probe results, capability assessment, and staged plan for
reducing redundancy and adding high-availability cloud fallbacks.

Prometheus alerts after sustained candidate failures or successful probe
latency above 20 seconds, keeping promotion decisions explicit.
The generated AI route also uses bounded retries for transient 429/5xx
responses, a concurrency circuit breaker, and passive endpoint ejection. This
policy applies to the generated route as a whole; it is deliberately not a
model-promotion or automatic cloud-fallback policy.

The approved five-model remote candidate pool is continuously probed every
five minutes by `openrouter-probe-exporter`. Prometheus records per-model
success, HTTP status, latency, consecutive failures, and the provider reported
by OpenRouter. These measurements inform the availability gates; they do not
enable cloud fallback automatically.
