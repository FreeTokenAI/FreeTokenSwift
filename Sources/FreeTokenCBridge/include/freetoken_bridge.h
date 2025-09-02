//
//  freetoken_bridge.h
//  FreeTokenCBridge
//
//  Optimized C bridge for llama.cpp operations to minimize FFI overhead
//

#ifndef FREETOKEN_BRIDGE_H
#define FREETOKEN_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Result structure for combined operations
typedef struct {
    int32_t token;           // Generated token
    float eval_time_ms;      // Evaluation time in milliseconds
    float sample_time_ms;    // Sampling time in milliseconds
    bool success;            // Operation success flag
} freetoken_result;

// Sampling configuration
typedef struct {
    float temperature;
    int32_t top_k;
    float top_p;
    float min_p;           // Min-P sampling threshold
    float typical_p;       // Typical-P sampling threshold
    float repeat_penalty;
    int32_t repeat_last_n;
    float frequency_penalty;
    float presence_penalty;
    int32_t mirostat;      // 0=disabled, 1=v1, 2=v2
    float mirostat_tau;    // Target entropy
    float mirostat_eta;    // Learning rate
    // DRY sampler parameters
    float dry_multiplier;  // DRY penalty strength (0.0 = disabled)
    float dry_base;        // DRY base value
    int32_t dry_allowed_length;  // How many tokens can repeat
    int32_t dry_penalty_last_n;  // Context window for DRY
    // XTC sampler parameters  
    float xtc_probability; // XTC probability threshold (0.0 = disabled)
    float xtc_threshold;   // XTC temperature threshold
    uint32_t seed;
    bool use_seed;
} freetoken_sampling_config;

// Initialize the bridge (call once at startup)
void freetoken_bridge_init(void);

// Cleanup the bridge (call once at shutdown)
void freetoken_bridge_cleanup(void);

// Session management - creates context with associated sampler
typedef struct freetoken_session* freetoken_session_t;

// Create a session (context + sampler)
freetoken_session_t freetoken_session_create(
    void* model,                        // llama_model*
    void* context,                      // llama_context*
    freetoken_sampling_config config    // Sampling configuration
);

// Free session (context and sampler)
void freetoken_session_free(freetoken_session_t session);

// Reset sampler state for new generation
void freetoken_session_reset_sampler(freetoken_session_t session);

// Feed tokens to sampler for proper penalty tracking
void freetoken_session_accept_tokens(
    freetoken_session_t session,
    const int32_t* tokens,
    int32_t count
);

// Combined operation: sample + eval + decode in one FFI call
// This is the main optimization - reduces Swift->C overhead
freetoken_result freetoken_generate_next(
    freetoken_session_t session,        // Session with context and sampler
    void* model,                        // llama_model* (for vocab)
    int32_t pos,                        // Current position in context
    int32_t seq_id                      // Sequence ID for KV cache
);

// Optimized batch evaluation
int32_t freetoken_eval_batch(
    void* context,                      // llama_context*
    const int32_t* tokens,              // Tokens to evaluate
    int32_t count,                      // Number of tokens
    int32_t start_pos,                  // Starting position
    int32_t batch_size,                 // Batch size limit
    int32_t seq_id                      // Sequence ID for KV cache
);

// Evaluate batch and feed tokens to session sampler
int32_t freetoken_eval_batch_with_session(
    freetoken_session_t session,        // Session with context and sampler
    const int32_t* tokens,              // Tokens to evaluate
    int32_t count,                      // Number of tokens
    int32_t start_pos,                  // Starting position
    int32_t batch_size,                 // Batch size limit
    int32_t seq_id                      // Sequence ID for KV cache
);

// Fast token to string conversion with pre-allocated buffer
// Returns number of bytes written, or -1 on error
int32_t freetoken_token_to_piece_fast(
    void* model,                        // llama_model*
    int32_t token,                      // Token to decode
    char* buffer,                       // Output buffer
    int32_t buffer_size                 // Buffer size
);

// Batch detokenization for multiple tokens at once
// Returns total bytes written
int32_t freetoken_tokens_to_text(
    void* model,                        // llama_model*
    const int32_t* tokens,              // Tokens to decode
    int32_t count,                      // Number of tokens
    char* buffer,                       // Output buffer
    int32_t buffer_size                 // Buffer size
);

// Get logits pointer without Swift overhead
const float* freetoken_get_logits_ptr(void* context);

// Get vocabulary size
int32_t freetoken_get_vocab_size(void* model);

// Get context from session (for other operations)
void* freetoken_session_get_context(freetoken_session_t session);

#ifdef __cplusplus
}
#endif

#endif // FREETOKEN_BRIDGE_H