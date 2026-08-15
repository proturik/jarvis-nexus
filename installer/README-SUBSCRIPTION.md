# JARVIS NEXUS ULTRA — Subscription installer (v12)

This installer builds a self-extracting IExpress EXE that installs a **versioned,
program-only** JARVIS NEXUS ULTRA tree, wires it to the signed private update
channel (auto-update), and enforces the optional subscription gate at every
launch. It mirrors the IExpress pattern of `Build-Installer-ULTRA.ps1`: an ASCII
staging root, a SED file, and exactly `iexpress.exe /N /Q <sed>`.

## What the installer produces

```
<InstallRoot>\app\                     <- versioned program-only dir
<InstallRoot>\app\.jarvis-program-marker
<InstallRoot>\app\version.txt          (1.0.0)
<InstallRoot>\app\release.json         (releaseId 'subscription-v12')
<InstallRoot>\app\ultra-server.mjs + public-ultra + assets + windows-control
<InstallRoot>\app\windows-theme + knowledge\jarvis-core.json
<InstallRoot>\app\conversation-intelligence.mjs + poe2-build-coach.mjs
<InstallRoot>\app\private-channel\     <- FULL private-channel dir (client updater
                                          + optional subscription gate + public key)
<InstallRoot>\data\                    <- empty (user data)
<InstallRoot>\sense-state\             <- empty (Sense state)
<InstallRoot>\runtime\node.exe
<InstallRoot>\desktop-shell\           (JarvisPet.exe + sense\JarvisSense.exe
                                          when present in the source tree)
<InstallRoot>\launcher\Start-Jarvis-RELEASE.ps1 + .cmd
<InstallRoot>\release.json             <- install-level manifest
```

The self-extracting EXE packages the whole tree as `payload.zip` plus a small
integrity-checked installer (`Install-Jarvis-SUBSCRIPTION.ps1` / `.cmd`). On
install it verifies the payload SHA-256 against `installer-manifest.json`, writes
the program-only directories fresh, and **never overwrites** `data\`,
`sense-state\` or `update-state\` — user data survives reinstall and updates.

## How subscription gating works

- The installer copies the **entire** `private-channel\` directory into
  `app\private-channel\`, including the production `public-key.xml` and the
  optional `Invoke-JarvisSubscriptionCheck.ps1` gate.
- The generated launcher sets `$env:JARVIS_DATA_DIR` to
  `<InstallRoot>\data` and then, **before** starting the core, runs the gate
  when it exists:

  ```powershell
  Invoke-JarvisSubscriptionCheck.ps1 -InstallRoot $AppRoot -DataRoot $DataRoot -PurchaseUrl <PurchaseUrl>
  ```

  A non-zero exit code stops the launch — the core is never started without a
  valid license. If the gate script is absent, the launcher simply skips it
  (the installer treats it as optional).

## How auto-update works

- The launcher then runs the bundled updater (when present) with **no**
  `-AutoConfirm`, so the «Обновить / Отмена» dialog is the update
  notification:

  ```powershell
  Invoke-JarvisUpdate.ps1 -ProgramRoot $AppRoot -IndexUrl <IndexUrl> `
      -DataRoot <InstallRoot>\data -StateRoot <InstallRoot>\update-state -Port 3791
  ```

- The updater verifies the signed release index against the pinned public key,
  downloads and verifies a newer package, and hands the running program off to
  the new version. It is safe on a non-versioned directory (returns
  `UpdateAvailable=false` without doing anything).

## Payments and licenses

Stripe payment automation is **intentionally deferred**. The purchase page
(`purchase.html` at the repo root, published on GitHub Pages) lists the plans
(Monthly $5 / Yearly $50 / Lifetime $150) with no-op Buy buttons. For now the
**owner issues the signed license file after payment** (see
`private-channel\README.md`, `New-JarvisSignedEnvelope.ps1 -Kind license`), and
the purchaser places it where the subscription gate reads it. The installer and
the update channel never handle payment credentials.

## Build

```powershell
# Default output: installer\dist-subscription\JARVIS-NEXUS-ULTRA-Subscription-Setup.exe
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\installer\Build-Installer-SUBSCRIPTION-v12.ps1
```

With an explicit Node runtime and output path:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\installer\Build-Installer-SUBSCRIPTION-v12.ps1 `
  -NodeRuntime C:\portable-node\node.exe `
  -OutputPath C:\build\JARVIS-NEXUS-ULTRA-Subscription-Setup.exe
```

Optional parameters:

| Parameter       | Default                                                    | Purpose                                  |
| --------------- | ---------------------------------------------------------- | ---------------------------------------- |
| `-NodeRuntime`  | auto (repo `runtime\node.exe`, then system node)           | Local node.exe v20+ to bundle            |
| `-OutputPath`   | `installer\dist-subscription\JARVIS-NEXUS-ULTRA-Subscription-Setup.exe` | EXE output            |
| `-WorkRoot`     | `C:\tmp\jarvis-iexpress`                                   | ASCII, space-free staging root           |
| `-PurchaseUrl`  | `https://proturik.github.io/jarvis-nexus/purchase.html`    | Baked into the launcher                  |
| `-IndexUrl`     | `https://proturik.github.io/jarvis-nexus/release-index.json` | Baked into the launcher                |
| `-SkipIExpress` | off                                                        | Stage only; write no EXE (test/audit)    |

The builder never overwrites an existing EXE or `.sha256.txt`, and never reuses
a staging directory. It returns a build summary object and preserves the staging
directory for audit.

## Test

Runs only in `%TEMP%` (never touches the repo `dist-*`):

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\installer\Test-Installer-SUBSCRIPTION.ps1
pwsh -NoLogo -NoProfile -File .\installer\Test-Installer-SUBSCRIPTION.ps1
```

The test stages with `-SkipIExpress`, asserts the staging layout (exact marker,
`version.txt`, `app\release.json`, private-channel bundle, empty `data\` and
`sense-state\`, launcher invocations, UTF-8 no BOM, `node --check` on
`ultra-server.mjs` when node is available), then performs a full IExpress build
into TEMP and verifies the EXE SHA-256 matches its `.sha256.txt`. Final marker:
`INSTALLER_SUBSCRIPTION_TESTS=PASS`.

## Notes

- The builder copies the **whole** `private-channel\` directory, including
  owner-side helper scripts; the production private key is never in the
  repository and never ships.
- The install-level `release.json` is separate from `app\release.json`, which
  is the versioned program identity consumed by `ultra-server.mjs`.
- The generated launcher is UTF-8 no BOM, uses `Set-StrictMode -Version Latest`
  and `$ErrorActionPreference = 'Stop'`, and never stops processes by image name.
