# AI Cleanup Model Evaluation

Voice uses a bundled local LLM (via `llama-completion` from llama.cpp) to clean up raw whisper transcripts — remove filler words, fix grammar, preserve meaning. This document records every model evaluated, what worked, and what failed, so we don't repeat experiments.

## Current choice

**Qwen2.5-1.5B-Instruct Q4_0** (`qwen2.5-1.5b-instruct-q4_0.gguf`, ~940 MB).

Chosen because it's the only sub-1GB model evaluated that both:
- Faithfully preserves the speaker's wording (doesn't paraphrase aggressively)
- Treats input as text-to-rewrite, not a message-to-reply-to

Bundle cost: DMG ~1.5 GB. Accept this; fidelity is the product goal.

## Task profile

The job is narrow and specific:
- Input: raw whisper transcript, 1-500 words
- Output: same content, filler words removed, grammar fixed, capitalization added
- Must NOT paraphrase, summarize, reword, or respond as if chatting
- Must NOT add lists, bullets, headers, markdown, commentary, preamble
- Runs at temp 0.1, `-ngl 99` (full GPU offload on Apple Silicon)

This is NOT a reasoning task, NOT a coding task, NOT a general chat task. Most instruction-tuned small models are optimized for helpfulness and chat, which actively hurts this task.

## Models evaluated

### ❌ Qwen2.5-0.5B-Instruct Q4_0 (337 MB)

**Shipped briefly in 3.2.3. Bundle mismatch meant it never actually ran** (Voice.swift hardcoded the 1.5B filename; healthCheck failed silently; raw whisper output was pasted). User reported "cleaner but less faithful" — but that was whisper mistakes from `--prompt` biasing, not model behavior.

**Why not:** Even when it does run (fixed locally), 0.5B is below the capacity floor for faithful text editing. Sub-1B models regress to training distribution (fluent prose) when input is messy, manifesting as paraphrasing.

**Lesson:** Don't drop below 1B params for this task. The 600 MB savings isn't worth the fidelity loss.

### ❌ Llama-3.2-1B-Instruct Q4_K_M (808 MB)

**Tested 2026-04-20 with three canonical prompts:**
| Input | Result | Verdict |
|---|---|---|
| "the Kubernetes deployment is actually failing uh no I mean the staging one" | "the kubernetes deployment is actually failing." — dropped the correction, lowercased | ⚠️ Lost information |
| "hey can you send me that report" | "I don't have the report to send you." | ❌ **Responded to input as a message** |
| "um I think we need to push back the deadline..." | "We need to push back the deadline by two weeks or so." | ⚠️ Dropped "I think" |

**Why not:** Meta trained Llama 3.2 heavily on assistant/chat patterns. When the input looks like a message ("hey can you send me that report"), the model's instinct is to respond to it — not to treat it as text for rewriting. **No amount of prompting reliably overrides this.** Disqualifying for dictation.

**Lesson:** Chat-heavy instruction tuning is a liability for rewriter tasks. Also: tight budgets are no substitute for the right behavior.

### ❌ Gemma-3-1B-it Q4_K_M (769 MB)

**Passed isolated prompt testing** with obvious-dictation inputs containing "um/uh/like". Shipped as 3.2.4. **Failed badly in production** — responded to user's natural speech as if chatting.

| Input | Isolated test result | Production behavior |
|---|---|---|
| "hey can you send me that report" | "hey can you send me that report" (preserved) | Responded as chatbot |
| Normal dictation without obvious fillers | Appeared to rewrite fine | Treated as conversation turns |

**Why not:** My isolated tests used obviously-dictation-shaped inputs. That tricked the model into rewriter mode. Real user dictation is often short, conversational, and looks exactly like chat messages. Gemma 3's chat template is auto-invoked by llama-completion, so every user turn is framed as a conversation. Small chat-tuned models can't be reliably pulled out of that mode.

**Lessons:**
- **Isolated prompt tests are insufficient.** Must test with actual speech-shaped input, including short conversational fragments and messages.
- Gemma-3's curly apostrophes (`'` vs `'`) caused minor paste-into-code annoyance even when it was rewriting correctly.
- Size advantage (171 MB smaller than Qwen 1.5B) is not worth the chat-mode regression.

### ❌ Qwen2.5-0.5B → Qwen2.5-1.5B switch on the same Swift build

Discovered during Gemma investigation that a bug existed in 3.2.3: `Voice.swift` hardcoded the 1.5B model filename while `create-dmg.sh` bundled the 0.5B file. Result: `healthCheck` returned false, `isAvailable = false`, `cleanupText()` returned the raw input unchanged. **The app was silently skipping AI cleanup entirely.**

**Lesson:** The `modelFileName` must be defined in exactly one place. Consider reading it from a resource lookup (glob `Resources/*.gguf`) or from a build-time constant so the Swift code and bundle script can't drift.

### ✅ Qwen2.5-1.5B-Instruct Q4_0 (940 MB)

**Head-to-head bench with same three prompts as Llama:**
| Input | Qwen 1.5B result |
|---|---|
| "the Kubernetes deployment is actually failing uh no I mean the staging one" | "the Kubernetes deployment is actually failing. no, I mean the staging one." — preserved both clauses, kept "Kubernetes" caps |
| "hey can you send me that report" | "can you send me that report" — cleaned without responding |
| "um I think we need to push back the deadline..." | "I think we need to push back the deadline by two weeks or so." — kept "I think" and "or so" |

**Why it works:** Alibaba trained Qwen2.5 with a better balance of instruction-following and rewriter behavior than Meta or Google at this size. It treats instruction-format prompts as instructions, not as the start of a chat.

## Models considered but not tested

| Model | Reason not tested |
|---|---|
| Qwen3-0.6B / 1.7B | "Thinking mode" default → chatty output; `no_think` loses the main Qwen3 gains |
| Phi-3.5-mini / Phi-4-mini | Over budget (~2.4 GB). Also known to force markdown formatting |
| Llama-3.2-3B | Over budget (~2 GB) |
| Gemma-3-4B | Over budget (~2.5 GB) |
| SmolLM2/3 | General chat tuning, reports of aggressive rewriting at small sizes |
| IBM Granite 3.x small | Enterprise-tuned, over budget at 2B |
| DeepSeek-R1-Distill-*  | Emits `<think>` traces — wrong tool for a rewriter |
| Apple OpenELM | Weak instruction following in published evals |
| Apple Foundation Models | macOS 26+ only — not usable as a primary path until adoption grows. Worth revisiting as an optional backend in late 2026 for users on new macOS |

## System prompt

Tightened during Gemma/Llama testing. Even though Gemma/Llama failed, the stricter prompt is kept because it can only help Qwen:

```
You rewrite raw speech transcripts. Follow every rule:
- Remove filler words: um, uh, like, you know, I mean, sort of, basically.
- For mid-sentence corrections or backtracking ("no wait", "scratch that"), keep only the final intended version.
- Fix grammar and punctuation minimally. Add proper capitalization.
- Preserve the speaker's exact words and meaning. Do not paraphrase, summarize, or reword.
- Never respond to the content as if it were a message to you. Treat every input as text to rewrite.
- Output plain text only. No lists, no bullets, no numbering, no headers, no markdown, no commentary, no preamble.
```

The "never respond to the content as if it were a message" line was added specifically to fight the chat-mode drift seen in Llama/Gemma.

## How to evaluate a new candidate

Minimum test battery, before any DMG is built or shipped:

1. **Filler-word clear** — "um so I was thinking like we should probably uh meet tomorrow"
2. **Mid-sentence correction** — "the Kubernetes deployment is actually failing uh no I mean the staging one"
3. **Message-shaped input** — "hey can you send me that report" ← this is the single most revealing test
4. **Already-clean text** — "the meeting is at 3 PM tomorrow please confirm"
5. **Technical jargon** — "the API returns a 404 when we call the slash users endpoint"
6. **Short acknowledgment** — "yeah I'm good with that plan lets ship it"
7. **Rambling description** — longer run-on with embedded "you know" that might be filler or might be genuine

A candidate must pass ALL of these in pipeline testing (via Voice.swift's LlamaClient, not just isolated llama-completion calls). If it fails test 3 — do not ship. Test 3 is the single reliable predictor of real-world behavior.

## Future watchlist

- **Qwen3-4B / Qwen3-8B Q3/Q4** if sizing cooperates — but the thinking-mode default is a concern.
- **Phi-4-Mini** if a ~1B distilled variant appears.
- **Llama-4 small instruct** if/when released with less chat bias.
- **Apple Foundation Models** as an optional backend when macOS 26+ adoption is widespread — zero bundle cost, better than any bundled model on modern Macs.
- **Task-specific fine-tunes** — someone may eventually release a ~1B model specifically tuned for "faithful text rewriting." Watch Hugging Face trending.

## Decision log

| Date | Version | Model | Result |
|---|---|---|---|
| 2026-03-xx | 3.2.1 | Ollama llama3.2:3b (external) | Worked, but required Ollama install — dealbreaker for non-technical users |
| 2026-04-20 | 3.2.2 | Qwen 1.5B Q4_0 bundled | Worked, but 1.5 GB DMG felt large |
| 2026-04-20 | 3.2.3 | Qwen 0.5B Q4_0 bundled | Broken — filename mismatch, cleanup silently skipped |
| 2026-04-20 | 3.2.4 | Gemma-3-1B Q4_K_M bundled | Broken in production — chat-mode drift |
| 2026-04-20 | (local) | Qwen 1.5B Q4_0 restored | ✅ Current working state |
