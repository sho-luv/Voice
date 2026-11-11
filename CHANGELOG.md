# Changelog

## Unreleased

### Performance and responsiveness

- Cache compiled custom-vocabulary rules until vocabulary changes, with synchronized access for concurrent cleanup calls.
- Move recording file writes onto a background queue and reuse eight audio buffers. Drain pending writes before closing recordings; report buffer overruns or write failures instead of transcribing incomplete capture.
- Normalize audio in memory, avoiding the intermediate WAV rewrite and reread.
- Search transcript history off the UI thread, reuse unchanged file contents, and prevent stale search results from replacing newer results. Integrated with the Voice 4.0 history panel.
- Reuse the cleanup model's common prompt-token prefix between requests, discarding the changed suffix and clearing cached state on decode failure.
- Skip the 150 ms focus delay when the intended destination app is already frontmost.

### Measured vocabulary improvement

On an Apple M4 Max, macOS 26.6.2, Swift 6.4 with `swiftc -O`, the production cache (including its lock) reduced repeated vocabulary processing per pass:

| Vocabulary | Previous | Cached | Saved per pass |
| --- | ---: | ---: | ---: |
| 10 terms | 1.2262 ms | 0.0088 ms | 1.2174 ms |
| 100 terms | 12.3116 ms | 0.0633 ms | 12.2483 ms |
| 500 terms | 61.4737 ms | 0.3005 ms | 61.1732 ms |

Measured on 2026-11-10 using seven alternating batches of 20 calls; values are median batch averages on a short transcript. Initial rule compilation still has its original cost. These are component measurements, not end-to-end dictation speedups. No measured speedup is claimed for the other changes above.

### Verification

- Native arm64 build and headless cleanup self-test.
- Twenty vocabulary output-equivalence comparisons covering empty input, Unicode, punctuation, word boundaries, and long text.
- Persistent self-test cases cover vocabulary edits, clearing, boundaries, escaped terms, and 100 concurrent calls with alternating vocabularies.
- Live microphone stress testing, Intel execution, and end-to-end latency comparisons remain unverified.

This entry is for the next release; no new public release or downloadable package has been published.
