# Llama.cpp Integration Plan & Progress

Last updated: 2025-08-25

Owner: FreeTokenSwift (roll-our-own-simplified-llama branch)

## 1. Objective
Implement an internal, minimal, maintainable local inference stack using the existing `llama.cpp` XCFramework, replacing prior `LocalLLMClient*` usage for on-device text (non‑multimodal) chat generation. Provide precise, message-level KV cache management with zero or near-zero full rebuilds.

## 2. Scope (In / Out)
In:
- Single resident llama.cpp session, single sequence id
- Message-level KV cache tracking and reconciliation (whole-message removals + tail appends)
- Streaming text generation (assistant) with stop sequences & cancellation (partial responses kept)
- Stateless raw completion path
- Tokenization API
- Error if images (local multimodal disabled)

Out / Deferred:
- Middle-out pruning (handled upstream; this manager only reflects authoritative message array)
- Multimodal (images) locally
- Multi-session / multi-sequence management
- Advanced speculative decoding / drafting
- Persistence / serialization of KV cache to disk

## 3. Functional Requirements
| # | Requirement | Notes |
|---|-------------|-------|
| 1 | Maintain resident llama.cpp session + hot KV cache | Single sequence id (0) |
| 2 | Track per-message token counts & spans | Store start/end for efficient removals |
| 3 | `updateContext(messages:)` reconciles to authoritative array | Remove any missing messages, append only tail additions |
| 4 | Reject unexpected middle insertions/reorders | Throw `unexpectedInsertion` error |
| 5 | Reject any image attachments | Throw `multimodalNotSupported` |
| 6 | Streaming `generate()` uses current KV, appends assistant span | Partial on cancel |
| 7 | `generate(text:)` raw completion, does not mutate KV | Stateless |
| 8 | Tokenize API | Direct pass-through |
| 9 | No internal pruning | Upstream supplies pruned list |
|10 | Minimal llama.cpp calls | rm, shift, decode, tokenize, sample |
|11 | Integrity checks after mutations | Invariant enforcement |
|12 | System message change: must be done via reset pattern | Changing in-place is unsupported |
|13 | Use central `FreeTokenError` for all new error cases | Extend existing error enum |

## 4. Non-Functional Requirements
- Simplicity: clear, linear logic (prefer errors over hidden complexity)
- Performance: O(tokens changed) operations; avoid full rebuild unless forced by first-message removal followed by lone new system message (handled as full clear + append)
- Reliability: defensive invariant checks with explicit errors
- Observability: structured logging for each context mutation & generation event
- Thread safety: all llama.cpp interactions through a single actor

## 5. Public API Draft
```
struct InitOptions { ... }
struct KVMessage { let message: Message; let tokenCount: Int }

final class LlamaManager {
  var kvMessages: [KVMessage] { get }
  init(modelPath: String, options: InitOptions) throws
  func updateContext(messages: [Message]) async throws
  func generate() async throws -> AsyncThrowingStream<String, Error>
  func generate(text: String) async throws -> AsyncThrowingStream<String, Error>
  func tokenize(_ text: String) throws -> [Int]
  func unload() async
}
```

## 6. Internal Data Structures
```
struct KVSpan {
  var start: Int      // inclusive token idx
  var end: Int        // exclusive token idx
  let hash: UInt64
  let message: Message
  var tokenCount: Int { end - start }
}
```

State:
- `spans: [KVSpan]`
- `totalTokensUsed: Int`
- `sequenceId: Int32 = 0`
- `busy: Bool`
- `session: LlamaSession` (actor)

## 7. Hash Strategy
Stable 64-bit hash over: `roleRaw + "\u{001F}" + content` using Swift `Hasher`. Stored with each span.

## 8. updateContext(messages:) Algorithm
Authoritative desired list D vs current tracked C:
1. Guard: no images.
2. Fast equality check.
3. Compute longest matching prefix p.
4. Scan existing spans from p:
   - If next desired matches -> keep.
   - If span’s hash appears later in desired tail -> throw `unexpectedInsertion`.
   - Else -> mark for removal.
5. Remaining desired tail messages after last kept = pure tail appends.
6. Perform removals (coalesce consecutive indices). For each group:
   - `rm(startToken, endToken)` then `shift(endToken ..< totalTokensUsed, -removedTokens)`.
   - Adjust subsequent spans.
7. Append tail messages (tokenize, eval, create spans).
8. Invariants validation.

System message changes: Caller must reset context (send only system message) first.

## 9. Generation
`generate()`:
1. Assume context synced by recent `updateContext`.
2. Capacity guard (headroom for `maxNewTokens + safetyBuffer`).
3. Optional assistant prefix (evaluated but not recorded until commit).
4. Sampling loop with penalties, topK/topP, stop sequences.
5. Cancellation: commit partial if any tokens produced (or prefix tokens exist).
6. Append assistant span.

`generate(text:)`: Stateless; does not mutate spans.

## 10. Errors (Using `FreeTokenError`)
No new standalone error enums will be created. Instead we extend or map to `FreeTokenError` as the central error surface for the package.

Proposed additional / repurposed cases (names illustrative; final naming to match existing style):
- `llamaUnexpectedInsertion` – An unexpected middle insertion or reordering detected in `updateContext`.
- `llamaMultimodalNotSupported` – Image (or other unsupported attachment) encountered for local inference.
- `llamaContextOverflow` – Not enough remaining context capacity (after upstream pruning) for requested operation.
- `llamaBusy` – A generate or context update is already in progress.
- `llamaInvariantViolation(message: String)` – Internal span/token invariant failed.
- `llamaModelLoadFailed(message: String)` – Failure initializing model or context.
- `llamaTokenizationFailed` – Tokenization call failed unexpectedly.
- `llamaGenerationStopped` (optional) – Generation terminated early (e.g. manual stop) distinct from cancellation if needed.

Mapping Strategy:
| Scenario | Thrown Error |
|----------|--------------|
| Image detected | `.llamaMultimodalNotSupported` |
| Unexpected insertion | `.llamaUnexpectedInsertion` |
| Capacity guard fail | `.llamaContextOverflow` |
| Busy state | `.llamaBusy` |
| Invariant failure | `.llamaInvariantViolation("detail")` |
| Model load fail | `.llamaModelLoadFailed("detail")` |
| Tokenize fail | `.llamaTokenizationFailed` |
| Manual early stop (if differentiated) | `.llamaGenerationStopped` |

Implementation Note: If adding new enum cases is undesirable, we can reuse a generic `.aiRunFailed(message:)` style case and standardize messages. Preference: explicit dedicated cases for observability & switch exhaustiveness.

## 11. Invariants
- Spans strictly increasing, contiguous: `spans[i].end == spans[i+1].start`.
- `totalTokensUsed == spans.last?.end ?? 0`.
- No overlapping spans.
- Capacity never exceeded.

## 12. Logging (Examples)
- Update: `removed=2(-512t) appended=1(+128t) total=2048/4096`
- Error: `unexpectedInsertion at desiredIndex=3`.
- Generate: `stream tokens=256 stop=EOS latency=1.24s t/s=206`.

## 13. Phase Plan & Status
| Phase | Title | Key Deliverables | Status | Notes |
|-------|-------|------------------|--------|-------|
| 1 | Skeleton & Types | Files, InitOptions, errors, hashing, empty session stub | Completed | Core types + errors merged |
| 2 | Session Core | Model/context load, tokenize, eval | Completed | Model/context handles + batching + logits |
| 3 | updateContext Core | Diff logic, removals (rm+shift), tail appends, invariants | Completed | rm/shift wired; invariants enforced |
| 4 | Generation Basic | Greedy/temperature sampling, streaming, cancellation | Completed | Streaming loop + stop detection + commit |
| 5 | Sampling Enhancements | topK/topP, repetition & presence/frequency penalties, stop seq | Completed | Unified sampling pipeline done |
| 6 | Assistant Prefix & Finalization | Prefix handling, partial commit policy | Completed | Prefix eval + stop trimming + commit |
| 7 | Robustness & Logging | Busy guards, integrity assertions, metrics | Completed | Metrics stored (tokens/sec, stopReason); zero compiler warnings; pending broader runtime validation |
| 8 | Integration Hook | Replace LocalLLMClient usages in AIModelManager | Completed | LocalLLMClient removed; internal LlamaManager live |
| 9 | Tests & Validation | Unit + integration tests, performance sanity | Pending | To be added end of refactor |
| 10 | Cleanup & Docs | README section, usage guide | Pending | Await integration completion |

## 14. Risk Register
| Risk | Impact | Likelihood | Mitigation | Status |
|------|--------|------------|------------|--------|
| llama shift/removal API differences | Incorrect KV adjustments | Medium | Validate symbols early; add abstraction layer | Open |
| Unexpected insertion by caller | Runtime error | Medium | Clear error guidance; caller fix upstream | Open |
| Token overflow after upstream pruning | Generation blocked | Low | Early guard & descriptive error | Open |
| Sampling correctness with penalties | Response quality | Medium | Add comparison tests vs simple baseline | Open |

## 15. Decision Log
| Date | Decision | Rationale |
|------|----------|-----------|
| 2025-08-25 | Error on middle insertion (no smart fallback) | Simplicity & predictability |
| 2025-08-25 | Upstream handles middle-out pruning | Single responsibility |
| 2025-08-25 | Store partial outputs on cancel | UX consistency |
| 2025-08-25 | Consolidate errors under FreeTokenError | Uniform error surface |

## 16. Open Questions
- None currently (all clarified). Add here if new uncertainties arise.

## 17. Progress Updates
Use appended dated bullet entries below.

### Update Log
- 2025-08-25: Phase 1 started. Added llama error cases, `LlamaTypes.swift`, `LlamaSession.swift` (stub), `LlamaManager.swift` (skeleton with updateContext scaffolding), plan updated.
- 2025-08-25: Adjusted visibility – removed `public` from Llama-related types/methods to keep API internal.
- 2025-08-25: Added developer documentation (`Docs/LlamaManagerDevGuide.md`) and enriched inline doc comments across Llama files.
- 2025-08-25: Phase 2 started. Added scaffolding fields for llama model/context handles in `LlamaSession` and plan status updated.
- 2025-08-25: Phase 2 progress: Implemented initial llama load/tokenize/eval wrappers (`LlamaBindings.swift`), integrated into `LlamaSession`.
- 2025-08-25: Phase 2 progress: Added chunked decode, logits accessor, greedy sampling stub.
- 2025-08-25: Phase 2 progress: Implemented unified sampling (temperature, topK, topP, penalties) with seeded RNG.
- 2025-08-25: Phase 2 progress: Added KV removal/shift wiring, token storage per span, naive detokenization, streaming generation prototype.
- 2025-08-25: Generation refinement: capacity guard, assistant prefix handling, stop trimming & commit logic.
- 2025-08-25: Logging integration: context update, removals, generation lifecycle, capacity overflow warnings.
- 2025-08-25: Integration refactor started: AIModelManager replacing LocalLLMClient path with internal LlamaManager (feature flag bypassed on branch).
- 2025-08-25: Plan sync: Phases 1–6 marked complete; Phase 7/8 marked in progress.
- 2025-08-25: Metrics added: generation tokens/sec, stop reason, refined cancellation (no commit if zero tokens) stored in `lastGenerationMetrics`.
- 2025-08-25: Compiler warnings driven to zero (deprecated llama APIs updated, String decoding modernized, unused mutability cleaned).
- 2025-08-25: Robustness phase (Phase 7) baseline complete: busy guards, invariant checks, metrics collection; awaiting integration test validation.
- 2025-08-25: Integration hook (Phase 8) complete: AIModelManager now exclusively uses internal LlamaManager; legacy LocalLLMClient paths removed.

## 18. Next Immediate Action
Immediate Priorities:
1. Test Suite (Phase 9): add unit + integration tests: updateContext edge cases, sampling determinism (seeded), stop sequence trimming accuracy, capacity overflow, cancellation partial commit behavior.
2. Precision Stop Trimming: refine token-level trimming so committed token list matches trimmed text exactly (avoid over-commit).
3. Metrics Expansion: expose generationLatencyMs, tokensGenerated cumulatively via a lightweight public accessor or logger format.
4. Documentation (Phase 10 prep): draft README section summarizing migration from LocalLLMClient and usage snippet for LlamaManager.
5. (Optional Optimization) Re-introduce KV cache targeted removals (seq_rm / seq_shift) once symbol support verified; replace full rebuild path.

---
_This document is the authoritative source of scope & progress for the llama.cpp integration. Keep synchronized with code changes._
