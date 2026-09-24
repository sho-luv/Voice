// Voice — local speech-to-text for macOS
// Copyright (C) 2026 Enfrosec LLC (dba Faraday Soft)
// SPDX-License-Identifier: GPL-3.0-or-later

// VoiceEngine.cpp — see VoiceEngine.h.
//
// Replaces the per-dictation `whisper-cli` / `llama-completion` subprocesses.
// Spawning those cost ~0.6 s (whisper) and ~0.95 s (llama) of process start,
// Metal init and model reload on every utterance, versus ~0.4 s and ~0.13 s of
// actual inference. Keeping the contexts resident in-process removes that.

#include "VoiceEngine.h"

#include "llama.h"
#include "parakeet.h"
#include "whisper.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

struct ve_asr {
    ve_asr_kind kind;
    whisper_context  * wctx = nullptr;
    parakeet_context * pctx = nullptr;
};

struct ve_llm {
    llama_model   * model = nullptr;
    llama_context * ctx   = nullptr;
    llama_sampler * smpl  = nullptr;
    const llama_vocab * vocab = nullptr;
    std::string tmpl;
};

static bool g_verbose = false;

static void ve_log(enum ggml_log_level level, const char * text, void *) {
    // CONT lines (e.g. the model-load progress dots) continue the previous
    // message, so they inherit its level rather than being filtered as-is.
    static enum ggml_log_level last = GGML_LOG_LEVEL_INFO;
    if (level != GGML_LOG_LEVEL_CONT) last = level;
    if (g_verbose || last >= GGML_LOG_LEVEL_ERROR) {
        fputs(text, stderr);
    }
}

static char * dup_string(const std::string & s) {
    char * out = static_cast<char *>(malloc(s.size() + 1));
    if (!out) return nullptr;
    memcpy(out, s.c_str(), s.size() + 1);
    return out;
}

void ve_init(bool verbose) {
    static std::once_flag once;
    g_verbose = verbose;
    std::call_once(once, [] {
        whisper_log_set(ve_log, nullptr);
        parakeet_log_set(ve_log, nullptr);
        llama_log_set(ve_log, nullptr);
        llama_backend_init();
    });
}

// MARK: - Speech recognition

ve_asr * ve_asr_load(const char * model_path, ve_asr_kind kind) {
    auto * asr = new ve_asr();
    asr->kind = kind;
    if (kind == VE_ASR_PARAKEET) {
        parakeet_context_params cparams = parakeet_context_default_params();
        cparams.use_gpu = true;
        asr->pctx = parakeet_init_from_file_with_params(model_path, cparams);
        if (!asr->pctx) { delete asr; return nullptr; }
    } else {
        whisper_context_params cparams = whisper_context_default_params();
        cparams.use_gpu    = true;
        cparams.flash_attn = true;
        asr->wctx = whisper_init_from_file_with_params(model_path, cparams);
        if (!asr->wctx) { delete asr; return nullptr; }
    }
    return asr;
}

char * ve_asr_transcribe(ve_asr * asr, const float * pcm, int n_samples,
                         const char * prompt, int n_threads) {
    if (!asr || !pcm || n_samples <= 0) return nullptr;
    std::string text;

    if (asr->kind == VE_ASR_PARAKEET) {
        parakeet_full_params params = parakeet_full_default_params(PARAKEET_SAMPLING_GREEDY);
        params.n_threads  = n_threads;
        params.no_context = true;
        if (parakeet_full(asr->pctx, params, pcm, n_samples) != 0) return nullptr;
        const int n = parakeet_full_n_segments(asr->pctx);
        for (int i = 0; i < n; ++i) {
            const char * seg = parakeet_full_get_segment_text(asr->pctx, i);
            if (!seg) continue;
            if (!text.empty() && seg[0] != ' ') text += ' ';
            text += seg;
        }
    } else {
        whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH);
        // Wider beam than the default 5: better on ambiguous / whispered audio
        // and nearly free once the model is resident (batched decode on Metal).
        params.beam_search.beam_size = 8;
        params.n_threads        = n_threads;
        params.language         = "en";
        params.detect_language  = false;
        params.translate        = false;
        params.no_context       = true;
        params.no_timestamps    = true;
        params.suppress_nst     = true;  // drop "[music]"-style non-speech tokens
        params.print_progress   = false;
        params.print_realtime   = false;
        params.print_special    = false;
        params.print_timestamps = false;
        if (prompt && prompt[0]) params.initial_prompt = prompt;
        if (whisper_full(asr->wctx, params, pcm, n_samples) != 0) return nullptr;
        const int n = whisper_full_n_segments(asr->wctx);
        for (int i = 0; i < n; ++i) {
            const char * seg = whisper_full_get_segment_text(asr->wctx, i);
            if (seg) text += seg;
        }
    }
    return dup_string(text);
}

void ve_asr_free(ve_asr * asr) {
    if (!asr) return;
    if (asr->wctx) whisper_free(asr->wctx);
    if (asr->pctx) parakeet_free(asr->pctx);
    delete asr;
}

// MARK: - Text cleanup LLM

ve_llm * ve_llm_load(const char * model_path, int n_ctx) {
    auto * llm = new ve_llm();

    llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = 99;
    llm->model = llama_model_load_from_file(model_path, mparams);
    if (!llm->model) { delete llm; return nullptr; }
    llm->vocab = llama_model_get_vocab(llm->model);

    const char * tmpl = llama_model_chat_template(llm->model, nullptr);
    if (!tmpl) { ve_llm_free(llm); return nullptr; }
    llm->tmpl = tmpl;

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx   = n_ctx;
    cparams.n_batch = n_ctx;
    cparams.no_perf = true;
    llm->ctx = llama_init_from_model(llm->model, cparams);
    if (!llm->ctx) { ve_llm_free(llm); return nullptr; }

    // Greedy: this is a rewrite task, not a creative one. Deterministic output
    // also makes the pipeline reproducible when debugging a bad cleanup.
    llm->smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(llm->smpl, llama_sampler_init_greedy());
    return llm;
}

static bool tokenize(const llama_vocab * vocab, const std::string & text,
                     std::vector<llama_token> & out) {
    const int n = -llama_tokenize(vocab, text.c_str(), (int32_t) text.size(), nullptr, 0, true, true);
    if (n <= 0) return false;
    out.resize(n);
    return llama_tokenize(vocab, text.c_str(), (int32_t) text.size(), out.data(), n, true, true) >= 0;
}

int ve_llm_count_tokens(ve_llm * llm, const char * text) {
    if (!llm || !text) return -1;
    std::vector<llama_token> toks;
    return tokenize(llm->vocab, text, toks) ? (int) toks.size() : -1;
}

char * ve_llm_generate(ve_llm * llm, const char * system, const char * user, int max_tokens) {
    if (!llm || !system || !user) return nullptr;

    llama_chat_message msgs[2] = { { "system", system }, { "user", user } };
    std::vector<char> buf(strlen(system) + strlen(user) + 512);
    int len = llama_chat_apply_template(llm->tmpl.c_str(), msgs, 2, true, buf.data(), (int32_t) buf.size());
    if (len > (int) buf.size()) {
        buf.resize(len);
        len = llama_chat_apply_template(llm->tmpl.c_str(), msgs, 2, true, buf.data(), (int32_t) buf.size());
    }
    if (len < 0) return nullptr;

    std::vector<llama_token> prompt;
    if (!tokenize(llm->vocab, std::string(buf.data(), len), prompt)) return nullptr;

    const int n_ctx = (int) llama_n_ctx(llm->ctx);
    if ((int) prompt.size() >= n_ctx - 8) return nullptr;
    if ((int) prompt.size() + max_tokens > n_ctx) max_tokens = n_ctx - (int) prompt.size();

    llama_memory_clear(llama_get_memory(llm->ctx), true);
    llama_sampler_reset(llm->smpl);

    std::string out;
    llama_batch batch = llama_batch_get_one(prompt.data(), (int32_t) prompt.size());
    llama_token tok;
    for (int i = 0; i < max_tokens; ++i) {
        if (llama_decode(llm->ctx, batch) != 0) return nullptr;
        tok = llama_sampler_sample(llm->smpl, llm->ctx, -1);
        if (llama_vocab_is_eog(llm->vocab, tok)) break;
        char piece[256];
        const int n = llama_token_to_piece(llm->vocab, tok, piece, sizeof(piece), 0, false);
        if (n < 0) return nullptr;
        out.append(piece, n);
        batch = llama_batch_get_one(&tok, 1);
    }
    return dup_string(out);
}

void ve_llm_free(ve_llm * llm) {
    if (!llm) return;
    if (llm->smpl)  llama_sampler_free(llm->smpl);
    if (llm->ctx)   llama_free(llm->ctx);
    if (llm->model) llama_model_free(llm->model);
    delete llm;
}

void ve_free(void * p) { free(p); }
