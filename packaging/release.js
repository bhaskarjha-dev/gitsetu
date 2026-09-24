#!/usr/bin/env node
'use strict';

// Dependency-free release policy and metadata renderer. Development checkouts
// intentionally have no installable v1.1.0 release URLs or digests.

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const MANIFEST_PATH = path.join(__dirname, 'release.json');
const ENV_PATH = path.join(__dirname, 'release.env');
const PACKAGE_PATH = path.join(ROOT, 'package.json');
const FLAKE_PATH = path.join(ROOT, 'flake.nix');
const CORE_PATH = path.join(ROOT, 'lib', 'core.sh');

const BUNDLE_MODULES = [
  'lib/core.sh',
  'lib/platform.sh',
  'lib/ui.sh',
  'lib/validate.sh',
  'lib/backup.sh',
  'lib/ssh.sh',
  'lib/gitconfig.sh',
  'lib/guard.sh',
  'lib/doctor.sh',
  'lib/verify.sh',
  'lib/teardown.sh',
  'lib/discovery.sh',
  'lib/setup.sh',
  'lib/keychain.sh',
  'lib/completion.sh'
];

const REQUIRED_ARTIFACTS = [
  'sourceArchive',
  'standalone',
  'windowsZip',
  'windowsExecutable',
  'npmPackage',
  'posixInstaller',
  'windowsInstaller',
  'packageManifests'
];

const TEMPLATE_TARGETS = [
  ['aur/PKGBUILD.in', 'aur/PKGBUILD'],
  ['aur/.SRCINFO.in', 'aur/.SRCINFO'],
  ['homebrew/gitsetu.rb.in', 'homebrew/gitsetu.rb'],
  ['scoop/gitsetu.json.in', 'scoop/gitsetu.json'],
  ['winget/BhaskarJha.GitSetu.yaml.in', 'winget/manifests/b/BhaskarJha/GitSetu/1.1.0/BhaskarJha.GitSetu.yaml'],
  ['winget/BhaskarJha.GitSetu.installer.yaml.in', 'winget/manifests/b/BhaskarJha/GitSetu/1.1.0/BhaskarJha.GitSetu.installer.yaml'],
  ['winget/BhaskarJha.GitSetu.locale.en-US.yaml.in', 'winget/manifests/b/BhaskarJha/GitSetu/1.1.0/BhaskarJha.GitSetu.locale.en-US.yaml']
];

function fail(message) {
  throw new Error(message);
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function requireString(value, field) {
  if (typeof value !== 'string' || value.length === 0) fail(`${field} must be a non-empty string`);
  return value;
}

function validateArtifact(name, artifact, manifest) {
  if (!artifact || typeof artifact !== 'object' || Array.isArray(artifact)) fail(`artifacts.${name} must be an object`);
  const file = requireString(artifact.file, `artifacts.${name}.file`);
  const url = requireString(artifact.url, `artifacts.${name}.url`);
  const digest = requireString(artifact.sha256, `artifacts.${name}.sha256`);
  const size = artifact.size;
  const signatureUrl = requireString(artifact.signatureUrl, `artifacts.${name}.signatureUrl`);
  const signatureBundleUrl = requireString(artifact.signatureBundleUrl, `artifacts.${name}.signatureBundleUrl`);
  const certificateIdentity = requireString(artifact.certificateIdentity, `artifacts.${name}.certificateIdentity`);

  if (!/^[0-9a-f]{64}$/.test(digest)) fail(`artifacts.${name}.sha256 must be a lowercase SHA-256 digest`);
  if (!Number.isSafeInteger(size) || size <= 0) fail(`artifacts.${name}.size must be a positive integer`);
  if (file !== path.basename(file) || file.includes('\\')) fail(`artifacts.${name}.file must be a basename`);

  const tag = manifest.release.tag;
  const expectedPrefix = `${manifest.sourceRepository}/releases/download/${tag}/`;
  for (const [field, value] of [['url', url], ['signatureUrl', signatureUrl], ['signatureBundleUrl', signatureBundleUrl]]) {
    if (!value.startsWith(expectedPrefix) || !value.startsWith('https://')) {
      fail(`artifacts.${name}.${field} must use the immutable ${tag} release URL`);
    }
  }
  if (!certificateIdentity.startsWith('https://github.com/bhaskarjha-dev/gitsetu/')) {
    fail(`artifacts.${name}.certificateIdentity is outside the GitSetu repository identity`);
  }
}

function validateManifest(manifest) {
  if (manifest.schemaVersion !== 1) fail('release manifest schemaVersion must be 1');
  if (manifest.name !== 'gitsetu') fail('release manifest name must be gitsetu');
  const version = requireString(manifest.version, 'version');
  if (!/^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$/.test(version)) fail(`invalid release version: ${version}`);
  if (manifest.sourceRepository !== 'https://github.com/bhaskarjha-dev/gitsetu') fail('unexpected sourceRepository');
  if (!manifest.release || typeof manifest.release !== 'object') fail('release policy is missing');
  if (!Array.isArray(manifest.aliases && manifest.aliases.commands) || manifest.aliases.commands.join(',') !== 'gitsetu,git-setu') {
    fail('command aliases must be exactly gitsetu and git-setu');
  }
  if (!Array.isArray(manifest.aliases && manifest.aliases.githubExtensions) || manifest.aliases.githubExtensions.join(',') !== 'gh-gitsetu,gh-setu') {
    fail('GitHub extension commands must be exactly gh-gitsetu and gh-setu');
  }
  for (const extensionName of manifest.aliases.githubExtensions) {
    const extensionPath = path.join(ROOT, 'packaging', 'gh-extension', extensionName);
    if (!fs.existsSync(extensionPath) || !fs.statSync(extensionPath).isFile() || fs.lstatSync(extensionPath).isSymbolicLink()) {
      fail(`GitHub extension command is missing or redirected: ${extensionName}`);
    }
    if (process.platform !== 'win32' && (fs.statSync(extensionPath).mode & 0o111) === 0) {
      fail(`GitHub extension command is not executable: ${extensionName}`);
    }
  }
  if (!manifest.runtime || manifest.runtime.bashMinimum !== '3.2') fail('runtime Bash policy must remain 3.2+');
  for (const dependency of ['bash', 'git', 'openssh', 'openssl', 'coreutils']) {
    if (!manifest.runtime.posix || !manifest.runtime.posix.includes(dependency)) fail(`missing POSIX runtime dependency: ${dependency}`);
  }
  if (!manifest.trust || manifest.trust.hashAlgorithm !== 'sha256' || manifest.trust.signatureScheme !== 'cosign-blob') {
    fail('trust policy must require SHA-256 and cosign blob signatures');
  }
  if (manifest.trust.oidcIssuer !== 'https://token.actions.githubusercontent.com') fail('unexpected OIDC issuer');

  const state = manifest.release.state;
  if (state === 'development') {
    if (manifest.release.prerelease !== true || manifest.release.public !== false) {
      fail('development must be explicitly prerelease and non-public');
    }
    if (manifest.release.tag !== null || manifest.release.commit !== null || manifest.release.publishedAt !== null) {
      fail('development metadata must not claim a tag, commit, or publication date');
    }
    if (!manifest.artifacts || Object.keys(manifest.artifacts).length !== 0) {
      fail('development metadata must not advertise release artifacts or stale digests');
    }
  } else if (state === 'released') {
    if (manifest.release.prerelease !== false || manifest.release.public !== true) {
      fail('released metadata must be public and non-prerelease');
    }
    if (manifest.release.tag !== `v${version}`) fail(`released tag must be v${version}`);
    if (!/^[0-9a-f]{40}$/.test(manifest.release.commit || '')) fail('released commit must be a full lowercase Git SHA');
    if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(manifest.release.publishedAt || '')) fail('publishedAt must be UTC ISO-8601');
    if (!manifest.artifacts || typeof manifest.artifacts !== 'object') fail('released artifact map is missing');
    for (const name of REQUIRED_ARTIFACTS) validateArtifact(name, manifest.artifacts[name], manifest);
    const extra = Object.keys(manifest.artifacts).filter((name) => !REQUIRED_ARTIFACTS.includes(name));
    if (extra.length) fail(`unexpected release artifacts: ${extra.join(', ')}`);
  } else {
    fail(`unsupported release state: ${state}`);
  }
  return manifest;
}

function loadManifest() {
  return validateManifest(readJson(MANIFEST_PATH));
}

function envText(manifest) {
  const released = manifest.release.state === 'released';
  const standalone = released ? manifest.artifacts.standalone : {};
  const lines = [
    '# Generated by packaging/release.js. Do not edit by hand.',
    `GITSETU_RELEASE_STATE=${manifest.release.state}`,
    `GITSETU_RELEASE_VERSION=${manifest.version}`,
    `GITSETU_RELEASE_TAG=${manifest.release.tag || ''}`,
    `GITSETU_RELEASE_COMMIT=${manifest.release.commit || ''}`,
    `GITSETU_ARTIFACT_URL=${standalone.url || ''}`,
    `GITSETU_ARTIFACT_SHA256=${standalone.sha256 || ''}`,
    `GITSETU_ARTIFACT_SIZE=${standalone.size || ''}`,
    `GITSETU_SIGNATURE_URL=${standalone.signatureUrl || ''}`,
    `GITSETU_SIGNATURE_BUNDLE_URL=${standalone.signatureBundleUrl || ''}`,
    `GITSETU_CERTIFICATE_IDENTITY=${standalone.certificateIdentity || ''}`,
    `GITSETU_CERTIFICATE_OIDC_ISSUER=${manifest.trust.oidcIssuer}`,
    `GITSETU_WINDOWS_ZIP_URL=${released ? manifest.artifacts.windowsZip.url : ''}`,
    `GITSETU_WINDOWS_ZIP_SHA256=${released ? manifest.artifacts.windowsZip.sha256 : ''}`,
    `GITSETU_WINDOWS_ZIP_SIZE=${released ? manifest.artifacts.windowsZip.size : ''}`,
    `GITSETU_WINDOWS_SIGNATURE_URL=${released ? manifest.artifacts.windowsZip.signatureUrl : ''}`,
    `GITSETU_WINDOWS_SIGNATURE_BUNDLE_URL=${released ? manifest.artifacts.windowsZip.signatureBundleUrl : ''}`
  ];
  return `${lines.join('\n')}\n`;
}

function coreVersion() {
  const source = fs.readFileSync(CORE_PATH, 'utf8');
  const match = source.match(/^GITSETU_VERSION="([^"]+)"$/m);
  if (!match) fail('could not read GITSETU_VERSION from lib/core.sh');
  return match[1];
}

function validateSourceConsistency(manifest) {
  const pkg = readJson(PACKAGE_PATH);
  if (pkg.version !== manifest.version) fail(`package.json version ${pkg.version} does not match ${manifest.version}`);
  if (pkg.name !== manifest.name) fail('package.json name does not match release manifest');
  if (pkg.private !== (manifest.release.state === 'development')) fail('package.json private flag does not match release state');
  if (!pkg.gitsetuRelease || pkg.gitsetuRelease.state !== manifest.release.state || pkg.gitsetuRelease.manifest !== 'packaging/release.json') {
    fail('package.json release-state metadata is missing or stale');
  }
  const expectedBins = { gitsetu: './bin/gitsetu.js', 'git-setu': './bin/gitsetu.js' };
  if (JSON.stringify(pkg.bin) !== JSON.stringify(expectedBins)) fail('package.json command aliases are inconsistent');
  if (coreVersion() !== manifest.version) fail('lib/core.sh version does not match release manifest');
  const flake = fs.readFileSync(FLAKE_PATH, 'utf8');
  if (!flake.includes(`upstreamVersion = "${manifest.version}"`)) fail('flake.nix upstreamVersion is stale');
  const expectedEnv = envText(manifest);
  const actualEnv = fs.readFileSync(ENV_PATH, 'utf8');
  if (actualEnv !== expectedEnv) fail('packaging/release.env is stale; run node packaging/release.js write-env');
  return pkg;
}

function sha256File(file) {
  const hash = crypto.createHash('sha256');
  hash.update(fs.readFileSync(file));
  return hash.digest('hex');
}

function replacements(manifest) {
  if (manifest.release.state !== 'released') fail('refusing to render installable manifests while release state is development');
  const a = manifest.artifacts;
  const tag = manifest.release.tag;
  const values = {
    VERSION: manifest.version,
    TAG: tag,
    COMMIT: manifest.release.commit,
    SHORT_COMMIT: manifest.release.commit.slice(0, 12),
    PUBLISHED_AT: manifest.release.publishedAt.slice(0, 10),
    SOURCE_FILE: a.sourceArchive.file,
    SOURCE_URL: a.sourceArchive.url,
    SOURCE_SHA256: a.sourceArchive.sha256,
    SOURCE_SIZE: String(a.sourceArchive.size),
    STANDALONE_FILE: a.standalone.file,
    STANDALONE_URL: a.standalone.url,
    STANDALONE_SHA256: a.standalone.sha256,
    STANDALONE_SIZE: String(a.standalone.size),
    WINDOWS_ZIP_FILE: a.windowsZip.file,
    WINDOWS_ZIP_URL: a.windowsZip.url,
    WINDOWS_ZIP_SHA256: a.windowsZip.sha256,
    WINDOWS_ZIP_SIZE: String(a.windowsZip.size),
    WINDOWS_EXE_FILE: a.windowsExecutable.file,
    WINDOWS_EXE_URL: a.windowsExecutable.url,
    WINDOWS_EXE_SHA256: a.windowsExecutable.sha256,
    LICENSE_URL: `${manifest.sourceRepository}/blob/${tag}/LICENSE`
  };
  return values;
}

function renderTemplate(content, values, file) {
  let output = content;
  for (const [key, value] of Object.entries(values)) {
    output = output.split(`{{${key}}}`).join(value);
  }
  if (/\{\{[A-Z0-9_]+\}\}/.test(output)) fail(`unresolved template token in ${file}`);
  return output;
}

function render(manifest, outputRoot) {
  const values = replacements(manifest);
  for (const [templateRel, targetRel] of TEMPLATE_TARGETS) {
    const templatePath = path.join(__dirname, 'templates', templateRel);
    const targetPath = path.join(outputRoot || __dirname, targetRel);
    const rendered = renderTemplate(fs.readFileSync(templatePath, 'utf8'), values, templateRel);
    fs.mkdirSync(path.dirname(targetPath), { recursive: true });
    fs.writeFileSync(targetPath, rendered, { flag: 'wx' });
  }
  process.stdout.write(`Rendered ${TEMPLATE_TARGETS.length} package manifests for ${manifest.release.tag}\n`);
}

function writeBundleManifest(manifest, bundlePath, bundleManifestPath, sourceCommit, sourceDirty, modulePaths) {
  if (!fs.existsSync(bundlePath) || !fs.statSync(bundlePath).isFile() || fs.lstatSync(bundlePath).isSymbolicLink()) fail('bundle artifact is missing or redirected');
  validateSourceConsistency(manifest);
  if (manifest.release.state === 'released' && sourceDirty !== 'clean') {
    fail('released bundles require a clean exact source checkout');
  }
  if (JSON.stringify(modulePaths) !== JSON.stringify(BUNDLE_MODULES)) fail('bundle module list is incomplete or reordered');
  const modules = modulePaths.map((relativePath) => {
    const absolutePath = path.join(ROOT, relativePath);
    if (!fs.existsSync(absolutePath) || !fs.statSync(absolutePath).isFile() || fs.lstatSync(absolutePath).isSymbolicLink()) fail(`bundle module is missing or redirected: ${relativePath}`);
    return { path: relativePath.replace(/\\/g, '/'), sha256: sha256File(absolutePath) };
  });
  const built = {
    schemaVersion: 1,
    name: manifest.name,
    version: manifest.version,
    releaseState: manifest.release.state,
    sourceCommit,
    sourceDirty,
    bundleSha256: sha256File(bundlePath),
    modules
  };
  fs.writeFileSync(bundleManifestPath, `${JSON.stringify(built, null, 2)}\n`);
  return built;
}

function verifyArtifacts(manifest, directory) {
  if (manifest.release.state !== 'released') fail('cannot verify public release artifacts while state is development');
  for (const name of REQUIRED_ARTIFACTS) {
    const artifact = manifest.artifacts[name];
    const file = path.join(directory, artifact.file);
    if (!fs.existsSync(file) || !fs.statSync(file).isFile() || fs.lstatSync(file).isSymbolicLink()) fail(`missing or redirected release artifact: ${name}`);
    const size = fs.statSync(file).size;
    if (size !== artifact.size) fail(`release artifact size mismatch: ${name}`);
    const digest = sha256File(file);
    if (digest !== artifact.sha256) fail(`release artifact digest mismatch: ${name}`);
  }
  process.stdout.write(`Verified ${REQUIRED_ARTIFACTS.length} exact release artifacts in ${directory}\n`);
}

function verifyBundle(bundlePath, bundleManifestPath, sourceManifest) {
  if (!fs.existsSync(bundlePath) || !fs.statSync(bundlePath).isFile() || fs.lstatSync(bundlePath).isSymbolicLink()) fail('bundle artifact is missing or redirected');
  const source = loadManifest();
  validateSourceConsistency(source);
  const built = readJson(bundleManifestPath);
  if (built.schemaVersion !== 1 || built.name !== source.name || built.version !== source.version) fail('bundle manifest identity mismatch');
  if (built.releaseState !== source.release.state) fail('bundle release state mismatch');
  if (!['clean', 'dirty', 'unavailable'].includes(built.sourceDirty)) fail('bundle source state is invalid');
  if (!/^[0-9a-f]{40}$|^unavailable$/.test(built.sourceCommit || '')) fail('bundle source commit is invalid');
  const modulePaths = Array.isArray(built.modules) ? built.modules.map((module) => module.path) : [];
  if (JSON.stringify(modulePaths) !== JSON.stringify(BUNDLE_MODULES)) fail('bundle module manifest is incomplete or reordered');
  if (built.bundleSha256 !== sha256File(bundlePath)) fail('bundle digest mismatch');
  for (const module of built.modules || []) {
    const modulePath = path.join(ROOT, module.path);
    if (!fs.existsSync(modulePath) || !fs.statSync(modulePath).isFile() || fs.lstatSync(modulePath).isSymbolicLink() || sha256File(modulePath) !== module.sha256) fail(`bundle module digest mismatch or redirected: ${module.path}`);
  }
  if (source.release.state === 'released') {
    if (built.sourceCommit !== source.release.commit) fail('bundle source commit does not match release manifest');
    if (built.bundleSha256 !== source.artifacts.standalone.sha256) fail('bundle bytes do not match released standalone artifact');
  }
  process.stdout.write(`Verified ${path.relative(ROOT, bundlePath)} against ${path.basename(bundleManifestPath)}\n`);
}

function usage() {
  fail('usage: node packaging/release.js <validate-source|write-env|render|write-bundle-manifest BUNDLE MANIFEST COMMIT DIRTY MODULE...|verify-artifacts DIRECTORY|verify-bundle BUNDLE MANIFEST>');
}

function main() {
  const command = process.argv[2];
  const manifest = loadManifest();
  if (command === 'validate-source') {
    validateSourceConsistency(manifest);
    process.stdout.write(`Release policy valid: ${manifest.version} (${manifest.release.state})\n`);
  } else if (command === 'write-env') {
    fs.writeFileSync(ENV_PATH, envText(manifest));
    process.stdout.write(`Wrote ${path.relative(ROOT, ENV_PATH)}\n`);
  } else if (command === 'render') {
    render(manifest, process.argv[3] ? path.resolve(process.argv[3]) : undefined);
  } else if (command === 'write-bundle-manifest') {
    if (process.argv.length < 8) usage();
    writeBundleManifest(
      manifest,
      path.resolve(process.argv[3]),
      path.resolve(process.argv[4]),
      process.argv[5],
      process.argv[6],
      process.argv.slice(7)
    );
  } else if (command === 'verify-artifacts') {
    if (!process.argv[3]) usage();
    verifyArtifacts(manifest, path.resolve(process.argv[3]));
  } else if (command === 'verify-bundle') {
    if (!process.argv[3] || !process.argv[4]) usage();
    verifyBundle(path.resolve(process.argv[3]), path.resolve(process.argv[4]), manifest);
  } else {
    usage();
  }
}

try {
  main();
} catch (error) {
  process.stderr.write(`release metadata error: ${error.message}\n`);
  process.exit(1);
}
