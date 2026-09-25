# GitSetu packaging and distribution policy

## Current release state

`v1.1.0` is a **verified, publication-ready release candidate**.
`packaging/release.json` remains the canonical source-policy record and
intentionally still declares the pre-publication state:

- `release.state = development`
- `release.prerelease = true`
- `release.public = false`
- no public tag, publication date, artifact URL, or digest in the tracked source

A local candidate bundle, Windows launcher/ZIP, npm tarball, and installers
have been built and verified. They are preparation artifacts only. The current
GitHub Actions workflow is **preparation-only**: it can build, hash, keyless-sign,
and attest a detached preparation bundle, but it has no publication credentials,
no `npm publish`, no GitHub release mutation, and no public release job.

Consequently, this branch does not publish installable AUR, Homebrew, Scoop, or
WinGet manifests and does not advertise a public v1.1.0 installer. The checked-in
`package.json` remains private for the same reason. Missing public v1.1.0 assets
are expected, not a release failure.

The `development` state and publication-ready wording are intentional. Do not
change them to `released` in a documentation-only commit. A public release must
first pass a separately reviewed publish-only workflow that consumes the exact
preparation run and its detached manifest.

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
| Windows installer | Test mode with a controlled local ZIP only | Windows ZIP/launcher, generated `release.env`, and detached manifest |
| npm | `npm pack` / `npx` from this checkout; package is private | npm tarball named by the detached manifest |
| GitHub CLI extensions | `packaging/gh-extension/gh-gitsetu` and `gh-setu` from this checkout | Signed, pinned standalone artifact |
| AUR / Homebrew / Scoop / WinGet | Templates are validated but must not be rendered | Generated only by a future publish-only workflow |

The npm command aliases are `gitsetu` and `git-setu` (the latter provides
`git setu`). GitHub CLI exposes one command per installed extension, so the
primary `gh-gitsetu` repository provides `gh gitsetu` and the separately packaged
`gh-setu` repository provides the compatibility command `gh setu`.

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
