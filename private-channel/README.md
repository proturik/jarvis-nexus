# JARVIS NEXUS private licence and update channel

This stage provides owner-only signing, strict offline verification, protected anti-replay state, safe ZIP staging, explicit activation and rollback, a signed HTTPS release index with a verified downloader, an opt-in process hand-off with a minimal updater UI, a program/data directory split, and an opt-in update check at startup. It does not yet publish anything automatically.

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

Issue a signed release index (list of published releases):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\private-channel\New-JarvisReleaseIndex.ps1 -OutputPath .\release-index.json -ReleasesJsonPath .\releases.json -ValidDays 7
```

`releases.json` is an array (or `{"releases":[...]}`) of entries with `version`, `releaseId`, `envelopeUrl`, `packageUrl` (both absolute HTTPS), `packageBytes`, `packageSha256`, `envelopeSha256` and `publishedAtUtc`. The index is signed like any other envelope and is never overwritten.

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

The activation target must be a program-only/versioned directory. Do not point it at a root containing profile, memory, history or other user data. Installer integration remains paused; launcher wiring is opt-in (see below).

The protected state defends against other local accounts, accidental rollback and ordinary writable-config tampering. A malicious process already running as the same Windows owner could replay a previously copied DPAPI blob; resisting that stronger attacker requires a remote monotonic release service or hardware-backed counter.

## Release index and downloader

The owner signs a release index that lists every published release (version, releaseId, HTTPS URLs to the update manifest and the ZIP package, exact byte size and SHA-256). Clients never trust the transport: they download the index, verify its signature against the pinned key, check expiry and channel, pick the newest version newer than the current one, then download the manifest and package.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Import-Module .\private-channel\Jarvis.ReleaseIndex.psm1 -Force; $r = Get-JarvisReleaseIndex -IndexUrl https://YOUR.HOST/release-index.json -IndexPath .\release-index.json -CurrentVersion 1.0.0; Get-JarvisReleasePackage -Release $r -OutputDirectory .\download"
```

Feed the returned `EnvelopePath`/`PackagePath` to `Invoke-JarvisStagedUpdate.ps1`.

Transport rules: HTTPS only (loopback HTTP is allowed only via an explicit test-only switch), no credentials in URLs, manual redirect handling that re-checks scheme and host on every hop, DNS resolution must not point to loopback/link-local/private/multicast addresses, bounded streaming with enforced size caps, and downloaded bytes must match the signed SHA-256 exactly before they are written into place.

### Publishing (GitHub Pages)

The chosen transport is **GitHub Pages** — static HTTPS hosting on `https://<user>.github.io/<repo>/`. Its public IPs and HTTPS certificate satisfy the downloader's checks, and it needs no per-request authentication (the downloader uses plain GET). Hosting the files publicly does not weaken the channel: trust comes entirely from the owner's signature and pinned SHA-256, and release packages contain no secrets. Note: Pages is free for a public repository; a private repository requires a paid GitHub plan.

Suggested layout on the Pages branch:

```
release-index.json
releases/<releaseId>/<releaseId>.update.json
releases/<releaseId>/jarvis-<version>.zip
```

Owner workflow for one release — the publisher script assembles the payload ZIP (excluding `data/`, `.env` and `private-channel/`), signs the manifest, records the release in `releases.json` and re-signs the index in one step:

```powershell
# ProgramRoot must already be a versioned program-only directory:
# it contains .jarvis-program-marker and a version.txt equal to -Version.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\private-channel\Publish-JarvisRelease.ps1 -ProgramRoot C:\release\app-1.1.0 -Version 1.1.0 -ReleaseId jarvis-1.1.0 -SiteRoot .\site -PublicUrlBase https://USER.github.io/jarvis-nexus -ValidDays 7
```

Then publish `site/` to the Pages branch (or the folder Pages is configured to serve) and push. The low-level manual path (ZIP → `New-JarvisSignedEnvelope` → hashes → `New-JarvisReleaseIndex`) remains available if finer control is needed.

`releases.json` entry example:

```json
{
  "version": "1.1.0",
  "releaseId": "jarvis-1.1.0",
  "envelopeUrl": "https://<user>.github.io/<repo>/releases/jarvis-1.1.0/jarvis-1.1.0.update.json",
  "packageUrl": "https://<user>.github.io/<repo>/releases/jarvis-1.1.0/jarvis-1.1.0.zip",
  "packageBytes": 12345,
  "packageSha256": "PASTE_PACKAGE_SHA256",
  "envelopeSha256": "PASTE_MANIFEST_SHA256",
  "publishedAtUtc": "2026-08-15T00:00:00Z"
}
```

## Opt-in process hand-off and updater UI

Hand-off stops the running JARVIS program, activates a verified update and restarts it. It is opt-in and never wired into the live launcher. The JARVIS core is identified as the process that owns the TCP listener on the port and whose command line references `<ProgramRoot>\ultra-server.mjs`; Pet/Sense are stopped only when their path is under the same program root. Nothing is ever killed by image name (`taskkill /IM node.exe` is forbidden), and an unattributable port owner causes a refusal.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\private-channel\Invoke-JarvisHandoff.ps1 -ProgramRoot C:\JARVIS\app-current -EnvelopePath C:\release\update.json -PackagePath C:\release\jarvis-1.1.0.zip -CurrentVersion 1.0.0
```

Standalone helpers: `Stop-JarvisProgram.ps1` and `Start-JarvisProgram.ps1`. The optional `Show-JarvisUpdatePrompt.ps1 -CurrentVersion 1.0.0 -NewVersion 1.1.0 -ReleaseNotes "..."` shows a «Обновить / Отмена» dialog and only decides; it never installs anything by itself. `Show-JarvisUpdateNotification.ps1` shows a non-blocking tray balloon («Доступно обновление JARVIS») for background checks while JARVIS is already running.

## Subscription licensing

Licences carry a billing tier: `monthly` (≤31 days), `yearly` (≤366 days) or `lifetime` (≤3651 days). Licences issued without a tier verify as `lifetime`, so older licences stay valid. The owner issues a licence with `New-JarvisSubscriptionLicense.ps1 -InstallId install-… -Tier yearly -OutputPath .\license.json`.

The client gate `Invoke-JarvisSubscriptionCheck.ps1` runs before the core starts: it resolves (or creates) the per-install ID in `<DataRoot>\install-id.txt`, verifies `<DataRoot>\license\license.json` against the pinned key, and on any failure shows a topmost «Требуется подписка JARVIS» dialog and exits non-zero — the core is never started. Payments are handled outside this code (Stripe for EU/US in the future); for now the owner issues the signed licence file after payment.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\private-channel\Invoke-JarvisSubscriptionCheck.ps1 -InstallRoot C:\JARVIS\app-current -DataRoot C:\JARVIS\data
```

The subscription installer (`installer\Build-Installer-SUBSCRIPTION-v12.ps1`) installs the versioned program-only layout with the bundled updater, the subscription gate and the startup update check; the purchase page is `purchase.html` served from GitHub Pages.

## Program/data split and startup update check

`ultra-server.mjs` roots all user data (conversations, memory, profile, settings, tasks, PoE2 builds) at `DATA_DIR`, which can be moved outside the versioned program directory with the `JARVIS_DATA_DIR` environment variable (`.env` can move via `JARVIS_ENV_FILE`). Without the override the original `ROOT\data` layout is used, so the current install keeps working unchanged. `Start-JarvisProgram.ps1` and `Invoke-JarvisHandoff.ps1` pass a stable `-DataRoot` (default `%LOCALAPPDATA%\JARVIS NEXUS ULTRA\data`) into the process, so an update replacing the program directory never touches user data.

The one-shot orchestrator `Invoke-JarvisUpdate.ps1` runs the whole flow: check the signed index, show the update prompt (unless `-AutoConfirm`), download and verify the manifest and package, then hand off. It is safe to call from the current mixed live install: if the directory is not a marked versioned program directory it returns `UpdateAvailable=false` without doing anything.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\private-channel\Invoke-JarvisUpdate.ps1 -ProgramRoot C:\JARVIS\app-current -IndexUrl https://YOUR.HOST/release-index.json -CurrentVersion 1.0.0
```

Launchers opt in: `Start-Jarvis-AtLogon.ps1 -UpdateIndexUrl https://YOUR.HOST/release-index.json` checks for updates before starting the core, and `RUN-JARVIS-NEXUS-ULTRA.cmd` checks only when the `JARVIS_INDEX_URL` environment variable is set. Both keep data in `%LOCALAPPDATA%\JARVIS NEXUS ULTRA\data` by default.

## Validation

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\private-channel\Test-PrivateChannel.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\private-channel\Test-OwnerIssuer.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\private-channel\Test-StagedUpdater.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\private-channel\Test-ReleaseIndex.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\private-channel\Test-Handoff.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\private-channel\Test-UpdateFlow.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\private-channel\Test-Subscription.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\installer\Test-Installer-SUBSCRIPTION.ps1
```

Tests cover signature/key pinning, wrong install IDs, payload/package tampering, replay/downgrade rejection, DPAPI state tampering, stage-only behavior, activation, rollback, ZIP-slip rejection, release-index tampering/expiry/wrong-key, HTTPS/redirect/DNS transport rejection, download size/hash mismatch, precise process hand-off including safety against stopping unrelated processes, the end-to-end update flow including data survival across an update, tier-aware subscription licences (monthly/yearly/lifetime, tampering, expiry, wrong install ID, backward compatibility), and the subscription installer staging/layout.

## Next private-channel stage

1. Publish `purchase.html` and the signed release index on GitHub Pages (`https://proturik.github.io/jarvis-nexus/`); the channel and installer are already wired to that URL.
2. Connect Stripe (EU/US cards) so purchases issue licences automatically via webhook; until then the owner issues the signed licence file after manual payment.
3. Add remote monotonic release state if same-user malware rollback is in scope.
3. Add remote monotonic release state if same-user malware rollback is in scope.
4. Installer integration only after the main application is finished.
