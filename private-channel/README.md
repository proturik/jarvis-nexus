# JARVIS NEXUS private licence and update channel

This stage provides owner-only signing and strict offline verification. It does not download, publish, install or activate updates.

## Trust model

- A production RSA-3072 private key is protected with Windows DPAPI (`CurrentUser`) under `%LOCALAPPDATA%\JARVIS NEXUS ULTRA\owner-secrets`.
- The private key never enters Git, an installer, an update package or a friend's PC.
- Distributed builds contain only `public-key.xml`. Its pinned SHA-256 fingerprint is `A935F9AC016C656C695A53A988C5EAD5CE30D42F6D57550A35311D7D8C0B455D`.
- Every installation uses a random install ID, never a hardware identifier.
- A licence authorises explicit install IDs and features. An update pins filename, byte length and SHA-256.
- Verification is fail-closed: strict UTF-8, pinned issuer key, exact signature, validity window, safe filename, package size/hash and a strictly newer numeric semantic version.

## Owner commands

Initialize or verify the production key (safe to repeat):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\private-channel\Initialize-JarvisSigningKey.ps1
```

Issue a licence:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\private-channel\New-JarvisSignedEnvelope.ps1 -Kind license -OutputPath .\license.json -InstallId install-PASTE_RANDOM_INSTALL_ID -Feature core,voice,vision -ValidDays 365
```

Issue an update manifest:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\private-channel\New-JarvisSignedEnvelope.ps1 -Kind update -OutputPath .\update.json -Version 1.1.0 -ReleaseId jarvis-1.1.0 -PackagePath C:\release\jarvis-1.1.0.zip -ValidDays 7
```

Issuer output files are never overwritten. Keep signed licences/manifests and release packages outside the source tree.

## Validation

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\private-channel\Test-PrivateChannel.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\private-channel\Test-OwnerIssuer.ps1
```

Tests cover valid licence/update envelopes, pinned-key mismatch, wrong install ID, modified payload/package and replay/downgrade rejection.

## Next private-channel stage

1. Private HTTPS transport and authenticated release index.
2. Persistent highest accepted release ID/version and trusted-time state.
3. Staged updater with a single verified file handle or equivalent anti-TOCTOU hand-off, rollback and UI.
4. Installer integration only after the main application is finished.
