# Semantic Router routing test

Date: 2026-09-14

Endpoint tested:

```text
https://llm.home.datalab.gg/v1/chat/completions
```

## Test method

Each request used the OpenAI-compatible API with `model: auto`:

```sh
curl --http2 --max-time 120 \
  -H 'content-type: application/json' \
  --data '{
    "model": "auto",
    "messages": [{"role": "user", "content": "<prompt>"}],
    "stream": false,
    "max_tokens": 128
  }' \
  https://llm.home.datalab.gg/v1/chat/completions
```

The `x-vsr-*` response headers were used to verify the Semantic Router decision,
confidence, reasoning mode, and selected model. The response body's `model`
field was checked independently.

## Results

| Case | Prompt | Decision | Selected model | Reasoning | Confidence | HTTP | Body model |
|---|---|---|---|---|---:|---:|---|
| Coding | `Write a Python function that reverses a linked list.` | `coding` | `qwen2.5-coder:14b` | off | 1.0000 | 200 | `qwen2.5-coder:14b` |
| Math | `What is the derivative of x cubed plus 2x?` | `math` | `phi4:14b` | on | 1.0000 | 200 | `phi4:14b` |
| Reasoning | `Analyze the tradeoffs carefully and compare these two designs.` | `reasoning` | `deepseek-r1:14b` | on | 1.0000 | 200 | `deepseek-r1:14b` |
| Default | `Give me a concise greeting for a new team member.` | `default` | `qwen3:14b` | off | 0.0000 | 200 | `qwen3:14b` |

All four requests returned response content. Because the test used
`max_tokens: 128`, each response ended with `finish_reason: length`; this is a
test limit and not a routing or upstream failure.

## Conclusion

The local routing policy is working end to end:

```text
Envoy Gateway → Semantic Router ExtProc → Agent Router → Ollama → selected model
```

The five Ollama models remain available through the Agent Router, and the
automatic policy now includes `gemma4:latest` for multimodal-oriented requests.
Cloud models and fallback routing are intentionally deferred to a later phase.
