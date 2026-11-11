# Changelog

## Unreleased

## 4.0.2 - 2026-11-10

### Security

- Update whisper.cpp from 1.9.4 to 1.9.5, which includes the upstream model-loader bounds-check fix, and pin both native inference dependencies to immutable commit hashes.
- Recheck every installed model against its pinned SHA-256 before loading it. Invalid downloaded models are rejected and removed, while model and transcript storage now uses private owner-only permissions.
- Pin GitHub Actions to full commit hashes, limit signing and notarization secrets to the exact steps that need them, and publish releases from a separate least-privilege job with no signing secrets.
- Accept update downloads only from approved HTTPS hosts, reject credentials and nonstandard ports, and validate update-server response status, origin, and size before parsing it.
- Store CLI coordination files in the user's private temporary directory instead of shared predictable `/tmp` paths.
- Make stapled-ticket and Gatekeeper checks mandatory for Developer ID release images, and verify the installed app's signature after copying it into `/Applications`.

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

- Universal arm64/x86_64 build and headless cleanup self-tests on both architectures.
- Twenty vocabulary output-equivalence comparisons covering empty input, Unicode, punctuation, word boundaries, and long text.
- Persistent self-test cases cover vocabulary edits, clearing, boundaries, escaped terms, and 100 concurrent calls with alternating vocabularies.
- Live microphone stress testing and end-to-end latency comparisons remain unverified.
