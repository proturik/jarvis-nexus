# JARVIS NEXUS private licence and update channel

This is the verification-only first stage. It does not download, install,
publish or activate anything.

## Trust model

- One offline RSA-2048 or stronger private key signs licence and update payloads.
- The private key stays only on the owner's signing machine. It is never stored
  in Git, an installer, an update package or a friend's PC.
- Distributed builds contain only the matching public key.
- Every installation receives a random install ID. Do not derive it from MAC,
  disk, CPU, Windows account or other hardware identifiers.
- A licence payload authorises explicit install IDs and feature names.
- An update payload pins the exact package filename, byte length and SHA-256.
- Verification happens before any package is unpacked or process is stopped.
- Failed verification is a hard stop. The current installation remains intact.

## Signed envelope

The envelope is JSON with `schemaVersion`, `algorithm`, `payloadBase64` and
`signatureBase64`. The signature covers the exact UTF-8 payload bytes, avoiding
ambiguous JSON canonicalisation.

Payload kind `license` contains:

- `issuer`, `licenseId`, `installIds`, `features`;
- UTC `notBefore` and `expiresAt` timestamps.

Payload kind `update` contains:

- `channel` (`private`), semantic `version`, `releaseId`;
- UTC `issuedAt` and `expiresAt` timestamps;
- `package.file`, `package.bytes` and `package.sha256`.

## Validation

Run locally:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\private-channel\Test-PrivateChannel.ps1
```

The tests generate an ephemeral key under the Windows temporary directory,
verify valid licence/update envelopes, reject another install ID, reject a
modified package and reject a modified signed payload. Test keys are deleted.

## Not implemented yet

1. Owner-only licence/update issuer UI.
2. Protected storage for the production signing key.
3. Private HTTPS transport and authentication.
4. Staged updater, process hand-off, rollback and update UI.
5. Installer integration; it remains intentionally paused.

