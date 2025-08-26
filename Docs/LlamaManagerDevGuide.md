# Llama Manager Developer Guide

Date: 2025-08-25

This guide explains how the internal llama.cpp integration works, how message-to-KV synchronization is performed, and where to extend or troubleshoot.

## High-Level Overview
`LlamaManager` maintains a *single* llama.cpp model + context (via `LlamaSession`) and a linear logical token stream that represents the current authoritative conversation (messages array). Each message is tracked as a contiguous token span (`_LlamaKVSpan`).

Synchronization is **unidirectional**: upstream code (outside this manager) decides which messages should be in the context (including any middle-out pruning). `updateContext(messages:)` reconciles the tracked spans to match that array exactly by:
1. Retaining a longest common prefix.
2. Removing any tracked messages not present afterward (whole messages only, never partial tokens).
3. Appending any *new* messages at the tail only.
4. Throwing an error if it detects an unexpected middle insertion / reordering.

## Why Simplicity Matters
Instead of sophisticated in-place partial rebuilds, the system enforces a strict contract: *only tail appends and arbitrary removals are allowed; new messages may not appear ahead of retained ones.* This dramatically reduces complexity and bug surface in KV cache maintenance.

## Key Types
| Type | Purpose |
|------|---------|
| `LlamaInitOptions` | Initialization & sampling configuration (context size, penalties, etc.). |
| `KVMessage` | Public-facing snapshot (message + tokenCount) for clients that need sizing / display. |
| `_LlamaKVSpan` | Internal bookkeeping of a message's token start/end in the logical sequence. |
| `LlamaSession` | Actor wrapping llama.cpp (model/context, tokenize, eval). |
| `LlamaManager` | Orchestrates spans, synchronization, generation (future phases). |

## Token Span Invariants
1. Spans are ordered; `spans[i].end == spans[i+1].start`.
2. `totalTokensUsed == spans.last?.end ?? 0`.
3. No overlap, no gaps.
4. Every span fully covers an original message without truncation or merging.

## updateContext Flow (Detailed)
Pseudo-process:
```
desired = authoritative messages
spans   = tracked current
1. Reject images (multimodal local unsupported).
2. If sequences identical => return.
3. Find prefix length p where spans[0...p-1] == desired[0...p-1].
4. From p forward, iterate existing spans:
   a. If matches next desired => keep & advance desired index.
   b. Else if span appears later in desired tail => throw unexpectedInsertion.
   c. Else => mark span for removal.
5. Remove marked spans (coalesce contiguous indices; will later call llama rm/shift APIs).
6. Append remaining desired tail messages (tokenize + eval + record spans).
7. Re-check invariants.
```

### Why Throw on Unexpected Insertion?
Allowing an in-context insertion forces shifting semantic positions of subsequent messages. That requires either (a) full rebuild or (b) complex partial replay logic. Throwing early keeps logic linear and predictable.

## Future llama.cpp Integration Points
The current skeleton omits direct llama.cpp calls. When wiring them (module imported as `import llama`):
| Operation | llama.cpp API (indicative) |
|-----------|---------------------------|
| Tokenize  | `llama_tokenize` |
| Decode    | `llama_decode` (batched) |
| Remove    | `llama_kv_cache_seq_rm` |
| Shift     | `llama_kv_cache_seq_shift` |
| Sampling  | Read logits + apply custom sampling in Swift |

> Verify actual symbols provided by the included XCFramework (module: `llama`); adjust function names accordingly.

## Error Mapping
All manager errors map into `FreeTokenError` (prefixed with `llama*`). This ensures downstream code has a uniform error handling surface.

## Partial Generation Handling (Planned)
During streaming, cancellation *after* any token is produced still commits a partial assistant message (for conversational continuity). If cancellation occurs before first token, nothing is appended.

## Adding a New Sampling Feature
1. Extend `LlamaInitOptions` if persistent config.
2. Inside future `LlamaSession.sample(...)`, integrate feature referencing logits.
3. Maintain backward-compatible defaults.
4. Add a test in Phase 9 for new sampling path.

## Troubleshooting Cheat Sheet
| Symptom | Possible Cause | Action |
|--------|----------------|--------|
| `llamaUnexpectedInsertion` | Upstream inserted a message before retained ones | Re-run prune logic upstream then retry |
| `llamaInvariantViolation` | Internal span math bug | Log spans, consider full rebuild fallback (future) |
| `llamaContextOverflow` | Upstream pruning insufficient | Prune more messages before calling update |
| Generation very slow | Oversized context or no batching | Profile; reduce context or batch decode |

## Extensibility Guidelines
- Keep `_LlamaKVSpan` simple; avoid embedding mutable token arrays.
- Favor adding narrow helper methods inside `LlamaManager` over introducing new types prematurely.
- Log *what* changed (counts/tokens) rather than *why* (left to upstream coordination logic).

## Open Extension Points
- Assistant prefix tokenization policies.
- Structured metrics (tokens/sec, latency) export.
- Panic recovery: full rebuild when invariants fail (currently just throws).

---
End of Developer Guide.
