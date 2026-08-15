# JARVIS NEXUS private licence and update channel

This stage provides owner-only signing, strict offline verification, protected anti-replay state, safe ZIP staging, explicit activation and rollback. It does not yet download or publish updates.

## Trust model

- A production RSA-3072 private key is protected with Windows DPAPI (`CurrentUser`) under `%LOCALAPPDATA%\JARVIS NEXUS ULTRA\owner-secrets`.
- The private key never enters Git, an installer, an update package or a friend's PC.
- Distributed builds contain only `public-key.xml`. Its pinned SHA-256 fingerprint is `A935F9AC016C656C695A53A988C5EAD5CE30D42F6D57550A35311D7D8C0B455D`.
- Every installation uses a random install ID, never a hardware identifier.
- A licence authorises explicit install IDs and features. An update pins filename, byte length and SHA-256.
- Verification is fail-closed: strict UTF-8, pinned issuer key, exact signature, validity window, safe filename, package size/hash and a strictly newer numeric semantic version.

## Owner commands

Initialize or verify the production key:

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

Issuer output files are never overwritten. Keep signed licences, manifests and release packages outside the source tree.

## Staged updater

Update ZIP files must contain only a `payload/` tree, and that tree must include the program directory marker file `.jarvis-program-marker` at its `payload/` root. The updater rejects path traversal, unsafe Windows names, duplicate paths, reparse-point roots, excessive file counts, expanded-size limits and suspicious compression ratios.

A program directory is recognised by a fixed marker file named `.jarvis-program-marker` whose exact content is `JARVIS NEXUS ULTRA program directory v1`. Activation refuses any current install or incoming payload that is missing or mismatching it, and rollback refuses unmarked backups.

The staging directory ACL is restricted to the current Windows owner and SYSTEM before extraction, so extracted payload children inherit that restricted ACL.

The DPAPI-protected state file is size-capped at 16 KiB and rejected if larger.

Verify and stage without changing the current program:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\private-channel\Invoke-JarvisStagedUpdate.ps1 -EnvelopePath C:\release\update.json -PackagePath C:\release\jarvis-1.1.0.zip -InstallRoot C:\JARVIS\app-current -CurrentVersion 1.0.0
```

Add `-Activate` only after JARVIS processes have exited. The updater never stops processes itself. Activation moves the old program directory to a sibling `.jarvis-backup-*` directory, moves the verified payload into place, and only then commits the DPAPI-protected version/release/time high-water mark.

Rollback keeps the anti-replay floor at the newest accepted version:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\private-channel\Restore-JarvisUpdateBackup.ps1 -InstallRoot C:\JARVIS\app-current -BackupPath C:\JARVIS\.jarvis-backup-1.1.0-PASTE_ID
```

The activation target must be a program-only/versioned directory. Do not point it at a root containing profile, memory, history or other user data. Installer and live-launcher integration remain paused.

The protected state defends against other local accounts, accidental rollback and ordinary writable-config tampering. A malicious process already running as the same Windows owner could replay a previously copied DPAPI blob; resisting that stronger attacker requires a remote monotonic release service or hardware-backed counter.

## Validation

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\private-channel\Test-PrivateChannel.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\private-channel\Test-OwnerIssuer.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\private-channel\Test-StagedUpdater.ps1
```

Tests cover signature/key pinning, wrong install IDs, payload/package tampering, replay/downgrade rejection, DPAPI state tampering, stage-only behavior, activation, rollback and ZIP-slip rejection.

## Next private-channel stage

1. Choose the private HTTPS host/domain and authentication method, then add the signed release index and downloader.
2. Integrate process hand-off with a versioned program-only directory and updater UI.
3. Add remote monotonic release state if same-user malware rollback is in scope.
4. Installer integration only after the main application is finished.
