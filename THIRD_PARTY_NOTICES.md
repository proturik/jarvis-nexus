# Third-party notices

This inventory is the distribution gate for JARVIS NEXUS. A friend build must
include the applicable upstream notices and licence texts. An unresolved entry
blocks packaging; the installer remains paused until this audit is complete.

## Architectural reference

- `isair/jarvis`, reviewed at commit
  `d22ed8b975792842dc09e49861f31a39cbb302a6`.
- Upstream licence: Jarvis AI Assistant License, copyright 2025 Baris Sencan.
- Source: <https://github.com/isair/jarvis>
- Licence: <https://github.com/isair/jarvis/blob/main/LICENSE>
- Current JARVIS NEXUS conversational-awareness code is an independent Windows
  implementation inspired by documented behaviour; no upstream source file was
  copied into the repository. Any future direct copy or derivative must retain
  the upstream copyright, licence and non-commercial terms.

## Bundled Python runtime inventory

The current local Sense build contains these packages. Versions and declared
licences were read from the installed package metadata on 2026-08-15:

| Component | Version | Declared licence |
| --- | ---: | --- |
| mss | 10.2.0 | MIT |
| numpy | 2.5.2 | BSD-3-Clause, 0BSD, MIT, Zlib and CC0 components |
| sounddevice | 0.5.5 | MIT |
| torch | 2.13.0+cpu | Apache-2.0 and bundled third-party licences |
| Pillow | 12.3.0 | MIT-CMU |
| certifi | 2026.7.22 | MPL-2.0 |
| charset-normalizer | 3.4.9 | MIT |
| tqdm | 4.70.0 | MPL-2.0 and MIT |
| setuptools | 84.0.0 | MIT |
| vosk Python package | 0.3.45 | Package metadata says `UNKNOWN`; resolve from the exact source distribution before packaging |

## Models and native binaries still requiring a release audit

- `vosk-model-small-ru-0.22` speech model and bundled `libvosk.dll`.
- Silero `v5_5_ru.pt` neural voice model.
- PortAudio/native libraries pulled in by sounddevice.
- PyTorch, NumPy and Pillow bundled native-library notice files.
- Node.js runtime, if included in a future friend package.
- JARVIS icon, wallpaper and other media provenance.

Local Ollama/Qwen/Llama models are installed separately and must not be bundled
in the update package. Their own licences apply to each user's local copy.

