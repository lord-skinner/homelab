# OpenRouter remote-model evaluation and routing plan

Date: 2026-09-14  
Scope: the 22 zero-prompt/zero-completion-price entries returned by the
OpenRouter model API. This is a planning artifact; it does not change live
Gateway routes.

## Executive summary

The free catalog is useful as a burst-capacity and modality pool, but it is
not a high-uptime foundation. Free-provider capacity is dynamic and several
models either returned provider overloads, rate limits, or are restricted to
agentic harnesses. Local Ollama should remain the primary path.

Recommended eventual policy:

1. Local Ollama first for ordinary text, coding, reasoning, math, and local
   vision.
2. A small remote shortlist for explicit overflow, cloud-only modality, or
   independent failure-domain redundancy.
3. Remote models should be selected by capability and health, not random
   `openrouter/free` routing.
4. Keep specialist models out of general-purpose fallback chains.
5. Add paid OpenRouter models later as the reliable tier; free models remain
   opportunistic unless repeated probes establish acceptable capacity.

## Live probe methodology

At 2026-09-14, each model received one minimal OpenAI-compatible text request
with `max_tokens=4`. Results measure reachability and approximate latency only;
they do not establish intelligence, sustained throughput, multimodal quality,
or a contractual rate limit. HTTP 200 with an error object is recorded as an
upstream failure.

OpenRouter's model metadata was obtained from its `/api/v1/models` endpoint.
The API exposes architecture, context, supported parameters, and pricing, but
not a stable per-model quota suitable for capacity planning. Rate-limit
ratings below are therefore based on this probe plus the earlier Gateway
smoke tests and must be re-measured over time.

## Model-by-model assessment

| Model | Best use | Modalities / context | Probe result | Initial disposition |
|---|---|---|---|---|
| `cohere/north-mini-code:free` | Agentic coding, tools | text→text / 256K | 200, 0.33s | Keep as remote coding backup |
| `nex-agi/nex-n2.5-pro:free` | Visual coding agents, verification | text+image→text / 256K | 200, 0.75s | Candidate high-value remote coding tier |
| `nex-agi/nex-n2.5-mini:free` | Lower-cost visual coding agent | text+image→text / 256K | 525, 41.9s | Remove from fallback; poor availability |
| `poolside/laguna-s-2.1:free` | Coding agents | text→text / 256K | 429, 0.16s | Remove from fallback; rate-limited |
| `poolside/laguna-xs-2.1:free` | Smaller coding agents | text→text / 256K | 429, 0.57s | Remove from fallback; rate-limited |
| `nvidia/nemotron-3-ultra-550b-a55b:free` | Frontier reasoning/orchestration | text→text / 1M | 200, upstream overloaded | Keep only as opportunistic benchmark target |
| `nvidia/nemotron-3-super-120b-a12b:free` | Complex multi-agent reasoning | text→text / 256K | 200, upstream overloaded | Remove from automatic fallback until stable |
| `nvidia/nemotron-3.5-lightning:free` | High-throughput agents | text→text / 1M | 200, 16.5s | Candidate overflow tier; latency concern |
| `nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free` | Multimodal perception sub-agent | text+image+audio+video→text / 256K | 200, 8.7s | Keep as modality backup; not latency-critical path |
| `nvidia/nemotron-3.5-content-safety:free` | Input/output moderation | text+image→text / 128K | 200, 0.29s | Keep only as guardrail, never answer fallback |
| `google/gemma-4-26b-a4b-it:free` | General multimodal reasoning | text+image+video→text / 256K | 429, 0.20s | Remove from automatic fallback pending capacity |
| `google/gemma-4-31b-it:free` | Larger multimodal reasoning | text+image+video→text / 256K | 429, 0.24s | Candidate only after capacity validation |
| `inclusionai/ling-3.0-flash-vl:free` | Vision/video/language tasks | text+image+video→text / 256K | 200, 0.80s | Keep as multimodal backup |
| `inclusionai/ling-3.0-flash-fin:free` | Finance analysis | text→text / 256K | 200, 0.87s | Specialist route only; safety review required |
| `inclusionai/ling-3.0-flash-sante:free` | Health/medicine analysis | text→text / 256K | 200, 1.16s | Specialist route only; never medical authority |
| `dots-studio/dots-3-note-preview:free` | Long-document/image notes and extraction | text+image→text / 512K | 200, 0.98s | Candidate document route; preview risk |
| `liquid/lfm-2.5-2.6b:free` | Extraction, RAG, lightweight agents | text→text / 64K | 200, 0.66s | Keep as low-cost/simple-task overflow |
| `thinkingmachines/inkling:free` | Large multimodal agentic reasoning | text+image+audio→text / 1M | 403 harness-only | Remove from ordinary API routing |
| `thinkingmachines/inkling-small:free` | Smaller multimodal agentic workflows | text+image+audio→text / 1M | 403 harness-only | Remove from ordinary API routing |
| `openrouter/free` | Random free-model selection | text+image→text / 200K | 200, selected unavailable Nex model | Do not use for deterministic routing |
| `google/lyria-3-pro-preview` | Music generation | text+image→audio / 1M | 200, 1.29s | Separate future audio product route |
| `google/lyria-3-clip-preview` | Short music clips | text+image→audio / 1M | 502, 0.76s | Separate route only after validation |

The two Lyria entries report zero text token pricing in the model catalog, but
their descriptions state per-song/per-clip charges. They must not be treated as
free until billing semantics are confirmed for the account.

## Capability tiers

### General text and coding

Local `qwen3:14b`, `qwen2.5-coder:14b`, `deepseek-r1:14b`, and `phi4:14b`
remain the deterministic primary tier. Remote candidates are North Mini Code,
Nex-N2.5-Pro, LFM2.5-2.6B, and eventually a paid high-quality model.

North is the strongest immediate remote candidate because it was fast and
successful in both the current probe and the prior Gateway test. Nex Pro has
useful visual-agent coverage but needs a larger tool-call benchmark. LFM is a
good efficiency tier, not a replacement for the coding or reasoning models.

### Vision, video, and audio

Use Ling VL and Nemotron Nano Omni as independent remote modality backups.
Gemma 4 26B/31B are attractive capability candidates, but both were rate
limited during this evaluation. Inkling has broad modalities but is not
available through ordinary API requests. Keep local Gemma 4 as the first
vision path.

### Specialists

Finance, health, and content-safety models should be explicit specialist
routes. They should not be silently selected by semantic similarity for general
questions. Health and finance outputs need application-level disclaimers and
human review where appropriate.

### Long context

Large context metadata does not prove usable quality or latency. Measure
retrieval accuracy and time-to-first-token at 32K, 128K, and 256K before using
the 512K/1M models for long documents. Local context limits and Ollama memory
pressure should be measured alongside remote options.

## Proposed routing architecture

```text
request
  ├─ explicit specialist/modality requirement
  │    ├─ moderation → Nemotron Content Safety
  │    ├─ audio/video → local Gemma 4, then Ling VL / Nemotron Omni
  │    ├─ coding → local Qwen Coder, then North, then Nex Pro
  │    └─ finance/health → explicit specialist route with policy controls
  ├─ ordinary text/reasoning → local Qwen / DeepSeek / Phi
  └─ local failure or saturation → health-scored remote candidate pool
```

Each remote candidate should have a circuit breaker, short per-provider
timeouts, exponential backoff for 429, and an ejection window after 429/5xx.
Do not fail over on malformed requests or policy/permission 403s. Preserve the
original task class during failover so a vision request does not fall back to a
text-only model.

## Staged plan

### Phase 1 — Baseline and remove obvious liabilities

- Keep only North, Nex Pro, LFM, Ling VL, and Nemotron Nano Omni as remote
  evaluation candidates.
- Exclude `openrouter/free`, both Inkling models, both Laguna models, Nex Mini,
  and currently overloaded Gemma/Nemotron Super/Ultra entries from automatic
  fallback.
- Keep Lyria outside the free LLM pool until billing is verified.
- Add per-model status, latency, 429, 5xx, timeout, and provider identity to
  Prometheus metrics.

### Phase 2 — Quality and modality benchmark

Run a fixed, versioned suite covering coding patches, Kubernetes diagnosis,
math, long-context extraction, tool calling, image understanding, video/audio
understanding, structured output, and refusal/safety behavior. Compare against
the local models using task success, groundedness, latency percentiles, and
tokens per successful task. A model only graduates when it improves a defined
class rather than merely producing fluent text.

### Phase 3 — Availability qualification

Run probes at realistic concurrency for at least 24 hours, then repeat during
peak periods. Track success rate, p50/p95 latency, 429 rate, 5xx rate,
timeout rate, and provider diversity. Suggested initial gates:

- general fallback: ≥99% successful probes, <2% 429/5xx, p95 <20s;
- multimodal fallback: ≥97% successful probes, p95 <45s;
- specialist/offline jobs: ≥95% successful probes, no silent capability loss.

These are proposed operating gates, not OpenRouter guarantees.

### Phase 4 — Controlled rollout

- Add only graduated models to Semantic Router cloud fallback decisions.
- Canary 5%, then 25%, then 100% of eligible overflow traffic.
- Keep local-first routing and a deterministic final fallback.
- Review weekly; free-model membership, provider capacity, and model behavior
  can change without notice.

## Current decision

Do not add all 22 models to the live router. The immediate cohesive pool is:

- primary local: all five Ollama models;
- remote coding: North Mini Code, with Nex Pro as a visual-coding candidate;
- remote simple/extraction: LFM2.5;
- remote vision/video: Ling VL, with Nemotron Nano Omni as a broader but slower
  backup;
- guardrail only: Nemotron Content Safety;
- evaluation-only: all remaining entries until they pass the quality and
  availability gates above.

Sources: [OpenRouter Models API](https://openrouter.ai/docs/api-reference/models),
[OpenRouter model routing](https://openrouter.ai/docs/features/model-routing),
[Envoy AI Gateway provider integration](https://aigateway.envoyproxy.io/docs/capabilities/llm-integrations/connect-providers/).
