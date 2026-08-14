# Third-party notices

This inventory is the distribution gate for JARVIS NEXUS. A friend build must include the applicable upstream notices and licence texts. The installer remains paused while the product is still being finished.

## Architectural reference

- `isair/jarvis`, reviewed at commit `d22ed8b975792842dc09e49861f31a39cbb302a6`.
- Upstream licence: Jarvis AI Assistant License, copyright 2025 Baris Sencan.
- Source: <https://github.com/isair/jarvis>
- Licence: <https://github.com/isair/jarvis/blob/main/LICENSE>
- JARVIS NEXUS uses an independent Windows implementation inspired by documented behaviour. No upstream source file was copied into this repository. Any future direct copy or derivative must retain the upstream copyright, licence and non-commercial terms.

## Sense runtime audited on 2026-08-15

| Component | Exact version | Licence source |
| --- | ---: | --- |
| Vosk Python wheel | 0.3.45 | Apache-2.0; exact wheel SHA-256 `6994ddc68556c7e5730c3b6f6bad13320e3519b13ce3ed2aa25a86724e7c10ac` |
| Vosk small Russian model | 0.22 | Apache-2.0 per the official Vosk model catalogue |
| Silero Russian TTS model | v5.5 | CC BY-NC-SA 4.0; non-commercial and attribution/share-alike conditions apply |
| Python | 3.12.13 | PSF licence |
| OpenSSL | 3.5.7 | Apache-2.0 |
| PortAudio / sounddevice | bundled / 0.5.5 | MIT |
| mss | 10.2.0 | MIT |
| numpy | 2.5.2 | BSD-3-Clause plus bundled component notices |
| torch | 2.13.0+cpu | BSD-style main licence plus bundled third-party notices |
| Pillow | 12.3.0 | MIT-CMU |
| certifi | 2026.7.22 | MPL-2.0 |
| charset-normalizer | 3.4.9 | MIT |
| tqdm | 4.70.0 | MPL-2.0 and MIT |
| setuptools | 84.0.0 | MIT |
| MarkupSafe | 3.0.3 | BSD-3-Clause |
| cffi / libffi | 2.1.1 / bundled | MIT / permissive libffi licence |
| Microsoft Visual C++ runtime | 14.51.36247 | Microsoft redistributable terms |

The authoritative static texts are stored in `third-party-licenses/static`. `Collect-SenseLicenses.ps1` copies those texts plus every licence shipped in the exact local Python build environment into a release bundle. It refuses to overwrite an existing output directory.

Example:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\third-party-licenses\Collect-SenseLicenses.ps1 -OutputDirectory C:\tmp\jarvis-sense-licenses
```

The friend package must include the generated directory unchanged. Local Ollama/Qwen/Llama models are installed separately and are not part of the update package; their own licences apply on each PC.

Still gated for any later release: Node.js notices if Node is bundled, and provenance/licensing for every wallpaper, icon, voice or other media asset. This file is a technical inventory, not legal advice.
