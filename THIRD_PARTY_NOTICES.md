# Third-Party Notices

Voice is licensed under the GNU General Public License v3.0 or later (see `LICENSE`).
It includes or downloads the following third-party components.

## Statically linked into the Voice executable

| Component | Version | License |
|-----------|---------|---------|
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (Whisper + Parakeet inference) | v1.9.4 | MIT |
| [llama.cpp](https://github.com/ggml-org/llama.cpp) (including ggml) | b11151 | MIT |

Both projects are distributed under the following license:

```
MIT License

Copyright (c) 2023-2026 The ggml authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Models downloaded on first launch

Models are not included in the app or this repository. Voice downloads them from Hugging Face and checks each one against a pinned SHA-256 hash.

| Model | Source | License |
|-------|--------|---------|
| Parakeet TDT 0.6B v3 (GGUF conversion) | [nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), converted by [ggml-org/parakeet-GGUF](https://huggingface.co/ggml-org/parakeet-GGUF) | [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/) (model weights, © NVIDIA) |
| Whisper large-v3-turbo (GGML Q5_0) | [openai/whisper-large-v3-turbo](https://huggingface.co/openai/whisper-large-v3-turbo), converted by [ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp) | MIT |
| Qwen2.5-1.5B-Instruct (GGUF Q4_0) | [Qwen/Qwen2.5-1.5B-Instruct-GGUF](https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF) | Apache-2.0 |
