# GitSetu packaging and distribution policy

## Current release state

`v1.1.0` release distribution is managed via GitHub Releases and npm.
`packaging/release.json` is the canonical metadata specification:

- GitHub Releases provides standalone binaries (`gitsetu`, `gitsetu-windows.zip`) and install scripts (`install.sh`, `install.ps1`).
- npm provides the Node.js package (`gitsetu` and `git-setu`).
- Package manager manifests (AUR, Homebrew, Scoop, WinGet) are withheld for v1.1.0.

## Release provenance model

Tracked release intent and generated publication facts are deliberately
separate:

- The annotated tag is resolved with `git rev-parse "refs/tags/<tag>^{commit}"`.
  No tracked file is required to contain the hash of the commit that contains it.
- `packaging/release-manifest.json` is generated **after** the assets exist. It
  records the tag, source commit, tag commit, workflow identity, and each
  artifact's size and SHA-256 digest. The manifest is not part of the source
  archive and does not contain its own digest.
- The source archive is made from the exact tagged source tree. If a future
  release uses a thin metadata commit, build the source archive and standalone
  bundle from the recorded `sourceCommit`, while the immutable tag records the
  `tagCommit`; never require those two commits to be equal by construction.
- `GITSETU_BUNDLE_SOURCE_COMMIT` may name that recorded source commit when
  building the standalone bundle from a clean metadata checkout. The override
  is rejected unless the commit exists and the checkout is clean.

This avoids both self-referential commit metadata and the temptation to write
an artifact digest back into a file that is included in that artifact's hash.

## Channels

| Channel | Development checkout policy | Release source |
|---|---|---|
| Standalone bundle | `bash scripts/bundle.sh` | Exact artifact and digest in the detached release manifest |
| POSIX installer | `bash install.sh --local-development` from a clean checkout | Installer, generated `release.env`, and detached manifest |
| Windows installer | `install.ps1` from a clean checkout or release archive | Windows ZIP/launcher, generated `release.env`, and detached manifest |
| npm | `npm pack` / `npx` from this checkout | npm package published to npm registry |

The npm command aliases are `gitsetu` and `git-setu` (the latter provides `git setu`).

## Development metadata and preparation

Release-manager templates live under `packaging/templates/`. They intentionally
contain `{{TOKEN}}` placeholders and are not directly installable. The tracked
`release.json` is not a place to record hashes generated after building the
assets. In development, rendering must continue to fail:

```bash
node packaging/release.js validate-source
node packaging/release.js render  # expected to fail
```

The preparation workflow creates a detached manifest after both build jobs have
uploaded their bytes. Its local equivalent is:

```bash
node packaging/release-manifest.js create \
  --directory release-assets \
  --output release-manifest.json \
  --tag v1.1.0 \
  --source-commit "$(git rev-parse HEAD)" \
  --tag-commit "$(git rev-parse HEAD)" \
  --phase core
node packaging/release-manifest.js verify \
  --manifest release-manifest.json \
  --directory release-assets \
  --phase core
```

The `core` phase covers the source archive, standalone, Windows, npm, installer,
and generated environment assets. A later publish phase may add rendered
package-manager manifests after their own bytes exist; the manifest is always
generated last and is never fed back into a hashed source input.

## Build and verification

```bash
node packaging/release.js validate-source
node packaging/release-manifest.js --help  # usage/error contract
node scripts/check-docs.mjs
make dist-check
make check
```

The bundle is written atomically as `dist/gitsetu`; its module list, source
state, version, and SHA-256 are recorded in `dist/gitsetu.manifest.json`.
Windows launcher output is normalized to deterministic bytes before packaging.
The Windows ZIP builder accepts only the explicit runtime file allowlist and
uses forward-slash ZIP member names.

The preparation workflow verifies the exact tag commit and clean checkout,
builds on the resolved commit rather than a mutable tag name, verifies every
core asset before signing, verifies every keyless signature with the workflow
identity, verifies checksums, and uploads a signed/attested preparation bundle.
It does not publish. A future publish-only workflow must require an explicit
protected-environment approval, accept only a named successful preparation run,
reverify every signature and attestation, publish idempotently, and leave no
public package behind when verification fails.
