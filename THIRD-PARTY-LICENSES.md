# Third-Party Licences

Trace is distributed under the [MIT Licence](LICENSE). It builds on the open-source
packages below. Each is the property of its respective authors and is used under
the terms of its own licence; those terms (and copyright notices) are preserved
here and travel with any redistribution of Trace.

All dependencies are resolved by Swift Package Manager (see `Package.resolved` for
exact pinned versions). None are copyleft — every licence below is in the
MIT / Apache-2.0 / BSD family and is compatible with Trace's MIT licence.

## Direct dependencies

| Package | Author | Licence | Source |
| --- | --- | --- | --- |
| FluidAudio | FluidInference | Apache-2.0 | https://github.com/FluidInference/FluidAudio |
| WhisperKit | Argmax, Inc. | MIT | https://github.com/argmaxinc/WhisperKit |
| Sparkle | The Sparkle Project | MIT (+ bundled BSD-2 / zlib components) | https://github.com/sparkle-project/Sparkle |
| DynamicNotchKit | Kai Azim (MrKai77) | MIT | https://github.com/MrKai77/DynamicNotchKit |

## Transitive dependencies

| Package | Author | Licence | Source |
| --- | --- | --- | --- |
| swift-transformers | Hugging Face | Apache-2.0 | https://github.com/huggingface/swift-transformers |
| swift-jinja | Hugging Face | Apache-2.0 | https://github.com/huggingface/swift-jinja |
| yyjson | YaoYuan (ibireme) | MIT | https://github.com/ibireme/yyjson |
| swift-argument-parser | Apple | Apache-2.0 | https://github.com/apple/swift-argument-parser |
| swift-asn1 | Apple | Apache-2.0 | https://github.com/apple/swift-asn1 |
| swift-collections | Apple | Apache-2.0 | https://github.com/apple/swift-collections |
| swift-crypto | Apple | Apache-2.0 | https://github.com/apple/swift-crypto |

## Notes

- **Sparkle** is redistributed in binary form (`Sparkle.framework`) inside the
  packaged `.app` / `.dmg` release artifacts, not in this source repository. Its
  full licence text — including the bundled bsdiff, sais-lite, and ed25519
  notices — is included in those release artifacts as required.
- **Models** (Parakeet, Whisper, Qwen3, and the FluidAudio diarisation models) are
  **not** bundled in this repository. They are downloaded at runtime from their
  respective providers (Hugging Face, Ollama) and remain subject to their own
  model licences.

## Apache-2.0 notice

This product includes software developed by the authors listed above under the
Apache Licence, Version 2.0. You may obtain a copy of the Apache Licence at
https://www.apache.org/licenses/LICENSE-2.0. Files licensed under Apache-2.0 are
distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND.

## Trademarks

Trace integrates with a number of third-party AI and transcription services and
displays each provider's name and logo solely to identify that service in the
app's settings (nominative use). All product names, logos, and brands are the
property of their respective owners — including, without limitation, OpenAI,
Anthropic, Google, Apple, Meta, Mistral, NVIDIA, Groq, DeepSeek, Alibaba (Qwen),
ElevenLabs, Deepgram, AssemblyAI, Speechmatics, Soniox, Rev, Fireworks, Voyage AI,
Hugging Face, Ollama, and OpenRouter. Their marks are **not** covered by Trace's
MIT licence, and their inclusion does not imply any affiliation with or
endorsement by those companies.
