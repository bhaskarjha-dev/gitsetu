#!/usr/bin/env node
'use strict';

// Dependency-free builder/validator for detached publication provenance.
// The tagged source tree records release intent; this generated manifest records
// facts that are only knowable after the assets have been built.

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const ARTIFACT_NAMES = [
  'sourceArchive',
  'standalone',
  'windowsZip',
  'windowsExecutable',
  'npmPackage',
  'posixInstaller',
  'windowsInstaller',
  'packageManifests',
  'releaseEnv'
];
const CORE_ARTIFACT_NAMES = ARTIFACT_NAMES.filter((name) => name !== 'packageManifests');
const ARTIFACT_FILES = Object.freeze({
  standalone: 'gitsetu-standalone',
  windowsZip: 'gitsetu-windows-x64.zip',
  windowsExecutable: 'gitsetu.exe',
  posixInstaller: 'install.sh',
  windowsInstaller: 'install.ps1',
  packageManifests: 'gitsetu-package-manifests.tar.gz',
  releaseEnv: 'release.env'
});

function fail(message) {
  throw new Error(message);
}

function selectedArtifactNames(phase) {
  if (!phase || phase === 'all') return ARTIFACT_NAMES;
  if (phase === 'core') return CORE_ARTIFACT_NAMES;
  fail(`unknown manifest phase: ${phase}`);
}

function usageText() {
  return 'usage: release-manifest.js create --directory DIR --output FILE --tag TAG --source-commit SHA [--tag-commit SHA] [--phase all|core] [--workflow-run ID] [--certificate-identity ID] [--created-at ISO] | verify --manifest FILE --directory DIR [--phase all|core] [--tag TAG] [--source-commit SHA] [--tag-commit SHA]';
}

function usage() {
  fail(usageText());
}

function parseArgs(args) {
  const command = args.shift();
  if (!command) usage();
  const options = {};
  for (let i = 0; i < args.length; i += 1) {
    const key = args[i];
    if (!key.startsWith('--') || i + 1 >= args.length) usage();
    options[key.slice(2)] = args[++i];
  }
  return { command, options };
}

function requiredOption(options, name) {
  if (!options[name]) fail(`--${name} is required`);
  return options[name];
}

function requireSha(value, label) {
  if (!/^[0-9a-f]{40}$/.test(value || '')) fail(`${label} must be a full lowercase 40-character Git SHA`);
  return value;
}

function requireIso(value, label) {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(value || '') || Number.isNaN(Date.parse(value))) {
    fail(`${label} must be UTC ISO-8601`);
  }
  return value;
}

function requireTag(tag) {
  if (!/^v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$/.test(tag || '')) fail(`invalid release tag: ${tag}`);
  return tag;
}

function safeAssetPath(directory, file) {
  if (typeof file !== 'string' || file.length === 0 || file.includes('\0') || path.basename(file) !== file) {
    fail(`asset filename must be a basename: ${file}`);
  }
  const root = path.resolve(directory);
  const full = path.resolve(root, file);
  const relative = path.relative(root, full);
  if (relative === '' || relative.startsWith(`..${path.sep}`) || relative === '..' || path.isAbsolute(relative)) {
    fail(`asset escapes directory: ${file}`);
  }
  if (!fs.existsSync(full)) fail(`missing asset: ${file}`);
  const stat = fs.lstatSync(full);
  if (!stat.isFile() || stat.isSymbolicLink()) fail(`asset must be a regular non-symlink file: ${file}`);
  return full;
}

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function git(args, cwd = ROOT) {
  return execFileSync('git', args, { cwd, encoding: 'utf8' }).trim();
}

function resolveTag(tag) {
  requireTag(tag);
  git(['show-ref', '--verify', '--quiet', `refs/tags/${tag}`]);
  return git(['rev-parse', `${tag}^{commit}`]);
}

function sourceVersion() {
  return JSON.parse(fs.readFileSync(path.join(ROOT, 'packaging', 'release.json'), 'utf8')).version;
}

function validateCommitRelationship(sourceCommit, tagCommit, skipGit) {
  requireSha(sourceCommit, 'source commit');
  requireSha(tagCommit, 'tag commit');
  if (sourceCommit === tagCommit) return;
  if (skipGit) return;
  try {
    git(['merge-base', '--is-ancestor', sourceCommit, tagCommit]);
  } catch {
    fail(`source commit ${sourceCommit} is not an ancestor of tag commit ${tagCommit}`);
  }
}

function artifactFile(name, version) {
  if (name === 'sourceArchive') return `gitsetu-${version}-source.tar.gz`;
  if (name === 'npmPackage') return `gitsetu-${version}.tgz`;
  return ARTIFACT_FILES[name];
}

function artifactMap(directory, names, version) {
  const artifacts = {};
  const files = new Set();
  for (const name of names) {
    const file = artifactFile(name, version);
    if (!file) fail(`unsupported artifact name: ${name}`);
    if (files.has(file)) fail(`duplicate artifact filename: ${file}`);
    files.add(file);
    const full = safeAssetPath(directory, file);
    artifacts[name] = { file, size: fs.statSync(full).size, sha256: sha256(full) };
  }
  return artifacts;
}

function create(options) {
  const directory = path.resolve(requiredOption(options, 'directory'));
  const output = path.resolve(requiredOption(options, 'output'));
  const tag = requireTag(requiredOption(options, 'tag'));
  const version = sourceVersion();
  if (tag !== `v${version}`) fail(`tag ${tag} does not match source version ${version}`);
  const phase = options.phase || 'all';
  const names = selectedArtifactNames(phase);
  const sourceCommit = requireSha(requiredOption(options, 'source-commit'), 'source commit');
  const skipGit = options['skip-git'] === 'true';
  const tagCommit = requireSha(options['tag-commit'] || (skipGit ? sourceCommit : resolveTag(tag)), 'tag commit');
  validateCommitRelationship(sourceCommit, tagCommit, skipGit);
  const createdAt = requireIso(options['created-at'] || new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'), 'created-at');
  const manifest = {
    schemaVersion: 1,
    name: 'gitsetu',
    version,
    tag,
    phase,
    sourceCommit,
    tagCommit,
    workflowRun: options['workflow-run'] || null,
    certificateIdentity: options['certificate-identity'] || null,
    createdAt,
    artifacts: artifactMap(directory, names, version)
  };
  // A manifest may live beside the assets, but must not replace one of them.
  if (Object.values(manifest.artifacts).some((artifact) => path.resolve(directory, artifact.file) === output)) {
    fail('manifest output must not be one of the assets');
  }
  fs.writeFileSync(output, `${JSON.stringify(manifest, null, 2)}\n`, { flag: 'wx' });
  process.stdout.write(`Created detached release manifest: ${output}\n`);
}

function verify(options) {
  const manifestPath = path.resolve(requiredOption(options, 'manifest'));
  const directory = path.resolve(options.directory || path.dirname(manifestPath));
  if (!fs.existsSync(manifestPath)) fail(`manifest is missing: ${manifestPath}`);
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  if (manifest.schemaVersion !== 1 || manifest.name !== 'gitsetu') fail('invalid release manifest identity');
  if (manifest.version !== sourceVersion()) fail('manifest version does not match source policy');
  requireTag(manifest.tag);
  if (manifest.tag !== `v${manifest.version}`) fail('manifest tag/version mismatch');
  const phase = options.phase || manifest.phase || 'all';
  const names = selectedArtifactNames(phase);
  if (manifest.phase && manifest.phase !== phase) fail(`manifest phase mismatch: expected ${manifest.phase}, requested ${phase}`);
  requireSha(manifest.sourceCommit, 'manifest source commit');
  requireSha(manifest.tagCommit, 'manifest tag commit');
  requireIso(manifest.createdAt, 'manifest created-at');
  if (manifest.workflowRun !== null && (typeof manifest.workflowRun !== 'string' || manifest.workflowRun.length === 0)) fail('invalid workflow run');
  if (manifest.certificateIdentity !== null && (typeof manifest.certificateIdentity !== 'string' || manifest.certificateIdentity.length === 0)) fail('invalid certificate identity');
  validateCommitRelationship(manifest.sourceCommit, manifest.tagCommit, options['skip-git'] === 'true');
  if (!manifest.artifacts || typeof manifest.artifacts !== 'object' || Array.isArray(manifest.artifacts)) fail('manifest artifacts are missing');
  const manifestNames = Object.keys(manifest.artifacts);
  for (const unknown of manifestNames) if (!ARTIFACT_NAMES.includes(unknown)) fail(`manifest contains unknown artifact: ${unknown}`);
  for (const required of names) if (!manifestNames.includes(required)) fail(`manifest is missing artifact: ${required}`);
  if (manifestNames.length !== names.length) fail('manifest contains artifacts outside its declared phase');
  const files = new Set();
  for (const name of names) {
    const artifact = manifest.artifacts[name];
    if (!artifact || typeof artifact !== 'object') fail(`manifest artifact is invalid: ${name}`);
    if (artifact.file !== artifactFile(name, manifest.version)) fail(`manifest artifact filename is not canonical: ${name}`);
    if (!Number.isSafeInteger(artifact.size) || artifact.size < 0) fail(`manifest artifact size is invalid: ${name}`);
    if (!/^[0-9a-f]{64}$/.test(artifact.sha256 || '')) fail(`manifest artifact digest is invalid: ${name}`);
    if (files.has(artifact.file)) fail(`duplicate artifact filename: ${artifact.file}`);
    files.add(artifact.file);
    const full = safeAssetPath(directory, artifact.file);
    if (artifact.size !== fs.statSync(full).size) fail(`artifact size mismatch: ${name}`);
    if (artifact.sha256 !== sha256(full)) fail(`artifact digest mismatch: ${name}`);
  }
  if (options.tag && manifest.tag !== options.tag) fail('manifest tag does not match requested tag');
  if (options['source-commit'] && manifest.sourceCommit !== options['source-commit']) fail('manifest source commit does not match requested commit');
  if (options['tag-commit'] && manifest.tagCommit !== options['tag-commit']) fail('manifest tag commit does not match requested commit');
  process.stdout.write(`Verified detached release manifest: ${manifestPath}\n`);
}

try {
  const { command, options } = parseArgs(process.argv.slice(2));
  if (command === 'create') create(options);
  else if (command === 'verify') verify(options);
  else if (command === 'help' || command === '--help' || command === '-h') process.stdout.write(`${usageText()}\n`);
  else usage();
} catch (error) {
  process.stderr.write(`release manifest error: ${error.message}\n`);
  process.exit(1);
}
