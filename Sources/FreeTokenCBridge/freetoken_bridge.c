//
//  freetoken_bridge.c
//  FreeTokenCBridge
//
//  Optimized C bridge implementation for llama.cpp operations
//  Now using native llama_sampler chain for better quality
//

#include "include/freetoken_bridge.h"

// Use direct headers when available to avoid modular header issues
#ifdef LLAMA_HEADERS_DIRECT
  #include "llama.h"
#else
  // Fallback to framework import
  #ifdef __has_include
    #if __has_include(<llama/llama.h>)
      #include <llama/llama.h>
    #elif __has_include("llama.h")
      #include "llama.h"
    #else
      #error "Cannot find llama.h"
    #endif
  #else
    #include <llama/llama.h>
  #endif
#endif

#include <string.h>
#include <stdlib.h>
#include <math.h>
#include <time.h>

// Simple performance timer
static inline double get_time_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1000000.0;
}

// Session structure to hold context and sampler together
typedef struct freetoken_session {
    void* context;              // llama_context*
    struct llama_sampler* sampler;  // Associated sampler chain
} freetoken_session;

void freetoken_bridge_init(void) {
    // Initialize any static resources if needed
}

void freetoken_bridge_cleanup(void) {
    // Cleanup any resources
}

// Create a sampler chain with configuration (internal helper)
static struct llama_sampler* create_sampler_chain(void* model, freetoken_sampling_config config) {
    // Initialize chain parameters
    struct llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
    sparams.no_perf = true;  // Disable performance tracking for efficiency
    
    struct llama_sampler* chain = llama_sampler_chain_init(sparams);
    if (!chain) return NULL;
    
    uint32_t seed = config.use_seed ? config.seed : (uint32_t)time(NULL);
    
    // Check for Mirostat (completely different sampling path)
    if (config.mirostat == 1) {
        // Mirostat v1: temperature -> mirostat
        if (config.temperature > 0.0f) {
            llama_sampler_chain_add(chain, llama_sampler_init_temp(config.temperature));
        }
        // Get vocab size from model
        const struct llama_vocab* vocab = model ? llama_model_get_vocab(model) : NULL;
        int n_vocab = vocab ? llama_vocab_n_tokens(vocab) : 32000;  // fallback
        llama_sampler_chain_add(chain, 
            llama_sampler_init_mirostat(n_vocab, seed, config.mirostat_tau, config.mirostat_eta, 100)
        );
        return chain;
    } else if (config.mirostat == 2) {
        // Mirostat v2: temperature -> mirostat_v2
        if (config.temperature > 0.0f) {
            llama_sampler_chain_add(chain, llama_sampler_init_temp(config.temperature));
        }
        llama_sampler_chain_add(chain,
            llama_sampler_init_mirostat_v2(seed, config.mirostat_tau, config.mirostat_eta)
        );
        return chain;
    }
    
    // Standard sampling chain (when mirostat is disabled)
    
    // 1. DRY sampler (most effective anti-repetition, applied first)
    if (config.dry_multiplier > 0.0f) {
        // Get vocab from model for DRY sampler
        const struct llama_vocab* vocab = model ? llama_model_get_vocab(model) : NULL;
        
        // Common sequence breakers (can be customized later)
        const char* seq_breakers[] = {"\n", ".", "!", "?", ",", ";", ":", " ", "\t", NULL};
        int num_breakers = 9;
        
        llama_sampler_chain_add(chain,
            llama_sampler_init_dry(
                vocab,
                2048,  // n_ctx_train (using reasonable default)
                config.dry_multiplier,
                config.dry_base > 0 ? config.dry_base : 1.75f,
                config.dry_allowed_length > 0 ? config.dry_allowed_length : 2,
                config.dry_penalty_last_n > 0 ? config.dry_penalty_last_n : 256,
                seq_breakers,
                num_breakers
            )
        );
    }
    
    // 2. XTC sampler (additional repetition control)
    if (config.xtc_probability > 0.0f) {
        llama_sampler_chain_add(chain,
            llama_sampler_init_xtc(
                config.xtc_probability,
                config.xtc_threshold > 0 ? config.xtc_threshold : 0.5f,
                1,  // min_keep
                seed
            )
        );
    }
    
    // 3. Traditional repetition penalties (still useful as backup)
    if (config.repeat_penalty != 1.0f || 
        config.frequency_penalty != 0.0f || 
        config.presence_penalty != 0.0f) {
        
        llama_sampler_chain_add(chain, 
            llama_sampler_init_penalties(
                config.repeat_last_n,     // penalty_last_n
                config.repeat_penalty,     // penalty_repeat  
                config.frequency_penalty,  // penalty_freq
                config.presence_penalty    // penalty_present
            )
        );
    }
    
    // 4. Top-K sampling
    if (config.top_k > 0 && config.top_k < 40000) {  // Sanity check
        llama_sampler_chain_add(chain, 
            llama_sampler_init_top_k(config.top_k)
        );
    }
    
    // 5. Typical-P sampling (alternative to top-p)
    if (config.typical_p > 0.0f && config.typical_p < 1.0f) {
        llama_sampler_chain_add(chain,
            llama_sampler_init_typical(config.typical_p, 1)  // min_keep=1
        );
    }
    
    // 6. Top-P (nucleus) sampling  
    if (config.top_p > 0.0f && config.top_p < 1.0f) {
        llama_sampler_chain_add(chain,
            llama_sampler_init_top_p(config.top_p, 1)  // min_keep=1
        );
    }
    
    // 7. Min-P sampling
    if (config.min_p > 0.0f) {
        llama_sampler_chain_add(chain,
            llama_sampler_init_min_p(config.min_p, 1)  // min_keep=1
        );
    }
    
    // 8. Temperature
    if (config.temperature > 0.0f) {
        llama_sampler_chain_add(chain,
            llama_sampler_init_temp(config.temperature)
        );
    }
    
    // 9. Final sampling from distribution
    llama_sampler_chain_add(chain,
        llama_sampler_init_dist(seed)
    );
    
    return chain;
}

// Create a session with context and sampler
freetoken_session_t freetoken_session_create(
    void* model,
    void* context,
    freetoken_sampling_config config
) {
    if (!context) return NULL;
    
    freetoken_session_t session = (freetoken_session_t)malloc(sizeof(struct freetoken_session));
    if (!session) return NULL;
    
    session->context = context;
    session->sampler = create_sampler_chain(model, config);
    
    if (!session->sampler) {
        free(session);
        return NULL;
    }
    
    return session;
}

// Free session and its sampler
void freetoken_session_free(freetoken_session_t session) {
    if (session) {
        if (session->sampler) {
            llama_sampler_free(session->sampler);
        }
        // Note: we don't free context here - that's managed by Swift
        free(session);
    }
}

// Reset sampler state for new generation
void freetoken_session_reset_sampler(freetoken_session_t session) {
    if (session && session->sampler) {
        llama_sampler_reset(session->sampler);
    }
}

// Feed tokens to sampler for proper penalty tracking
void freetoken_session_accept_tokens(freetoken_session_t session, const int32_t* tokens, int32_t count) {
    if (!session || !session->sampler || !tokens || count <= 0) return;
    
    for (int i = 0; i < count; i++) {
        llama_sampler_accept(session->sampler, tokens[i]);
    }
}

// Get context from session
void* freetoken_session_get_context(freetoken_session_t session) {
    return session ? session->context : NULL;
}

freetoken_result freetoken_generate_next(
    freetoken_session_t session,
    void* model,
    int32_t pos,
    int32_t seq_id
) {
    freetoken_result result = {0};
    
    if (!session || !session->context || !session->sampler || !model) {
        result.success = false;
        return result;
    }
    
    void* context = session->context;
    struct llama_sampler* sampler = session->sampler;
    
    double start_time;
    
    // Sample token using the native sampler chain
    start_time = get_time_ms();
    
    // -1 means sample from all sequences (we only have one per session)
    llama_token token = llama_sampler_sample(sampler, context, -1);
    
    result.token = token;
    result.sample_time_ms = (float)(get_time_ms() - start_time);
    
    // CRITICAL: Accept the token to update sampler state for proper penalty tracking
    llama_sampler_accept(sampler, token);
    
    // Evaluate the sampled token
    start_time = get_time_ms();
    
    // Create batch for single token
    struct llama_batch batch = llama_batch_init(1, 0, 1);
    batch.token[0] = token;
    batch.pos[0] = pos;
    batch.n_seq_id[0] = 1;
    batch.seq_id[0][0] = seq_id;
    batch.logits[0] = 1;  // We need logits for next prediction
    batch.n_tokens = 1;
    
    int rc = llama_decode(context, batch);
    llama_batch_free(batch);
    
    result.eval_time_ms = (float)(get_time_ms() - start_time);
    result.success = (rc == 0);
    
    return result;
}

int32_t freetoken_eval_batch(
    void* context,  // Still takes raw context for batch operations
    const int32_t* tokens,
    int32_t count,
    int32_t start_pos,
    int32_t batch_size,
    int32_t seq_id
) {
    // Delegate to the new function with needs_logits = true for backward compatibility
    return freetoken_eval_batch_ex(context, tokens, count, start_pos, batch_size, seq_id, true);
}

// Extended version with explicit logits control for optimized prompt evaluation
int32_t freetoken_eval_batch_ex(
    void* context,
    const int32_t* tokens,
    int32_t count,
    int32_t start_pos,
    int32_t batch_size,
    int32_t seq_id,
    bool needs_logits  // Only calculate logits for the very last token if true
) {
    if (!context || !tokens || count <= 0) return -1;
    
    int32_t processed = 0;
    
    while (processed < count) {
        int32_t remaining = count - processed;
        int32_t chunk_size = remaining > batch_size ? batch_size : remaining;
        bool is_last_chunk = (processed + chunk_size >= count);
        
        struct llama_batch batch = llama_batch_init(chunk_size, 0, 1);
        
        for (int i = 0; i < chunk_size; i++) {
            batch.token[i] = tokens[processed + i];
            batch.pos[i] = start_pos + processed + i;
            batch.n_seq_id[i] = 1;
            batch.seq_id[i][0] = seq_id;
            // Only calculate logits for the very last token of the entire sequence if needed
            batch.logits[i] = (needs_logits && is_last_chunk && i == chunk_size - 1) ? 1 : 0;
        }
        batch.n_tokens = chunk_size;
        
        int rc = llama_decode(context, batch);
        llama_batch_free(batch);
        
        if (rc != 0) return -1;
        
        processed += chunk_size;
    }
    
    return processed;
}

// Evaluate batch and feed tokens to session sampler
int32_t freetoken_eval_batch_with_session(
    freetoken_session_t session,
    const int32_t* tokens,
    int32_t count,
    int32_t start_pos,
    int32_t batch_size,
    int32_t seq_id
) {
    // Delegate to extended version with needs_logits = true for backward compatibility
    return freetoken_eval_batch_with_session_ex(session, tokens, count, start_pos, batch_size, seq_id, true);
}

// Extended version with explicit logits control
int32_t freetoken_eval_batch_with_session_ex(
    freetoken_session_t session,
    const int32_t* tokens,
    int32_t count,
    int32_t start_pos,
    int32_t batch_size,
    int32_t seq_id,
    bool needs_logits
) {
    if (!session || !session->context) return -1;
    
    // First evaluate the batch with logits control
    int32_t result = freetoken_eval_batch_ex(
        session->context,
        tokens,
        count,
        start_pos,
        batch_size,
        seq_id,
        needs_logits
    );
    
    // If successful, feed tokens to sampler for penalty tracking
    if (result > 0 && session->sampler) {
        freetoken_session_accept_tokens(session, tokens, count);
    }
    
    return result;
}

int32_t freetoken_token_to_piece_fast(
    void* model,
    int32_t token,
    char* buffer,
    int32_t buffer_size
) {
    if (!model || !buffer || buffer_size <= 0) return -1;
    
    const struct llama_vocab* vocab = llama_model_get_vocab(model);
    if (!vocab) return -1;
    
    int32_t written = llama_token_to_piece(vocab, token, buffer, buffer_size, 0, false);
    return written;
}

int32_t freetoken_tokens_to_text(
    void* model,
    const int32_t* tokens,
    int32_t count,
    char* buffer,
    int32_t buffer_size
) {
    if (!model || !tokens || !buffer || buffer_size <= 0) return -1;
    
    const struct llama_vocab* vocab = llama_model_get_vocab(model);
    if (!vocab) return -1;
    
    int32_t total_written = 0;
    char* current = buffer;
    int32_t remaining = buffer_size;
    
    for (int i = 0; i < count && remaining > 0; i++) {
        int32_t written = llama_token_to_piece(vocab, tokens[i], current, remaining, 0, true);
        if (written <= 0) break;
        
        current += written;
        remaining -= written;
        total_written += written;
    }
    
    return total_written;
}

const float* freetoken_get_logits_ptr(void* context) {
    return context ? llama_get_logits(context) : NULL;
}

int32_t freetoken_get_vocab_size(void* model) {
    if (!model) return 0;
    const struct llama_vocab* vocab = llama_model_get_vocab(model);
    return vocab ? llama_vocab_n_tokens(vocab) : 0;
}
