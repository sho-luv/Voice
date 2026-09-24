// Voice — local speech-to-text for macOS
// Copyright (C) 2026 Enfrosec LLC (dba Faraday Soft)
// SPDX-License-Identifier: GPL-3.0-or-later

// VoiceEngine.h — minimal C surface over whisper.cpp, parakeet (whisper.cpp)
// and llama.cpp, all statically linked against one shared ggml.
//
// Swift sees only these functions. Every returned string is malloc'd and must
// be released with ve_free(). No function here is thread-safe per handle —
// callers serialize access to a given ve_asr / ve_llm.

#ifndef VOICE_ENGINE_H
#define VOICE_ENGINE_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ve_asr ve_asr;
typedef struct ve_llm ve_llm;

typedef enum {
    VE_ASR_WHISPER  = 0,
    VE_ASR_PARAKEET = 1,
} ve_asr_kind;

// Backend init + log routing. Safe to call more than once.
void ve_init(bool verbose);

ve_asr * ve_asr_load(const char * model_path, ve_asr_kind kind);
// pcm: 16 kHz mono float samples in [-1, 1].
// prompt: whisper initial prompt (ignored by parakeet); may be NULL.
// Returns NULL on failure.
// language: ISO code ("en", "es", …) for Whisper; NULL or "auto" auto-detects.
// Parakeet is inherently multilingual and ignores this.
char *   ve_asr_transcribe(ve_asr * asr, const float * pcm, int n_samples,
                           const char * prompt, const char * language, int n_threads);
void     ve_asr_free(ve_asr * asr);

ve_llm * ve_llm_load(const char * model_path, int n_ctx);
// Applies the model's built-in chat template to [system, user] and decodes
// greedily until end-of-generation or max_tokens. Returns NULL on failure.
char *   ve_llm_generate(ve_llm * llm, const char * system, const char * user,
                         int max_tokens);
// Number of tokens `text` encodes to, or -1 on failure.
int      ve_llm_count_tokens(ve_llm * llm, const char * text);
void     ve_llm_free(ve_llm * llm);

void     ve_free(void * p);

#ifdef __cplusplus
}
#endif

#endif
