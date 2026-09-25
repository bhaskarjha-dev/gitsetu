# GitSetu packaging and distribution policy

## Current release state

`v1.1.0` is a **verified local release candidate**, not a public release.
`packaging/release.json` remains the canonical policy record and intentionally
still declares the pre-publication state:

- `release.state = development`
- `release.prerelease = true`
- `release.public = false`
- no tag, publication date, artifact URL, or digest

A local candidate bundle, Windows launcher/ZIP, npm tarball, and installers
have been built and verified. They are preparation artifacts only: they are
not signed, rendered into public package-manager manifests, tagged, or
published. The canonical release state changes only after the intentional
release workflow completes.

Consequently, this branch does not publish installable AUR, Homebrew, Scoop, or
WinGet manifests and does not advertise a public v1.1.0 installer. The checked-in
`package.json` is private for the same reason. Missing public v1.1.0 assets are
expected, not a release failure.

The `development` state and candidate/unpublished wording are intentional. Do
not change them to `released` in a documentation-only commit; the release
workflow must first create the clean commit, immutable tag, exact signed
artifacts, provenance, and public URLs.

## Channels

| Channel | Development checkout policy | Release source |
|---|---|---|
| Standalone bundle | `bash scripts/bundle.sh` | Exact `standalone` artifact in `release.json` |
| POSIX installer | `bash install.sh --local-development` from a clean checkout | `posixInstaller` + adjacent `release.env` |
| Windows installer | Test mode with a controlled local ZIP only | `windowsInstaller` + adjacent `release.env` |
| npm | `npm pack` / `npx` from this checkout; package is private | npm tarball from the release job |
| GitHub CLI extensions | `packaging/gh-extension/gh-gitsetu` and `gh-setu` from this checkout | Signed, pinned standalone artifact |
| AUR / Homebrew / Scoop / WinGet | Templates are validated but must not be rendered | Generated only from a `released` manifest |

The npm command aliases are `gitsetu` and `git-setu` (the latter provides
`git setu`). GitHub CLI exposes one command per installed extension, so the
primary `gh-gitsetu` repository provides `gh gitsetu` and the separately packaged
`gh-setu` repository provides the compatibility command `gh setu`.

## Development metadata templates

Release-manager inputs live under `packaging/templates/`. They intentionally
contain `{{TOKEN}}` placeholders and are not directly installable. Once a release
is intentionally approved, update `packaging/release.json` to `released`, add
the exact commit and signed artifact metadata, regenerate `release.env`, and run:

```bash
node packaging/release.js validate-source
node packaging/release.js write-env
node packaging/release.js render
```

In development, `node packaging/release.js render` must fail. This prevents an
unreleased branch from acquiring installable claims or stale v1.0.0 hashes.

## Build and verification

```bash
node packaging/release.js validate-source
node scripts/check-docs.mjs
make dist-check
make check
```

The bundle is written atomically as `dist/gitsetu`; its module list, source
state, version, and SHA-256 are recorded in `dist/gitsetu.manifest.json`.
Windows launcher output is normalized to deterministic bytes before packaging.
The Windows ZIP builder accepts only the explicit runtime file allowlist and
uses forward-slash ZIP member names.

The release workflow must verify the full Git commit, all exact artifact bytes,
cosign signatures, generated checksums, and provenance before changing a draft
GitHub release to public. Pull requests and development builds never receive a
publication token.
