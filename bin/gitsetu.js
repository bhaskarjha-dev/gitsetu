#!/usr/bin/env node
'use strict';

const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const rootDir = path.resolve(__dirname, '..');
const entryScript = path.join(rootDir, 'gitsetu');
const bundleScript = path.join(rootDir, 'dist', 'gitsetu');
let targetScript = fs.existsSync(entryScript) ? entryScript : bundleScript;

function fail(message, code = 1) {
  console.error(`\x1b[31m[Error]\x1b[0m ${message}`);
  process.exit(code);
}

// Git for Windows accepts native drive paths, while Node may expose the same
// locations through MSYS paths (for example /c/Users/... or C:\\Users\\...).
// Normalize only the child environment; never rewrite the package root or
// trusted shell discovery inputs.
function normalizeWindowsChildPath(value) {
  if (typeof value !== 'string' || value.length === 0) return value;
  const normalized = value.replace(/\\/g, '/');
  const msysDrive = normalized.match(/^\/([A-Za-z])(?:\/(.*))?$/);
  if (msysDrive) return `${msysDrive[1].toUpperCase()}:/${msysDrive[2] || ''}`;
  return normalized;
}

function canonicalizeWindowsChildEnvironment(env) {
  const rawHome = typeof env.HOME === 'string' ? env.HOME : '';
  const homeLooksWindows = /^[A-Za-z]:[\\/]/.test(rawHome) || /^\/[A-Za-z](?:[\\/]|$)/.test(rawHome);
  const home = normalizeWindowsChildPath(homeLooksWindows ? rawHome : (env.USERPROFILE || rawHome));
  if (home) {
    env.HOME = home;
    env.USERPROFILE = home;
    const drive = home.match(/^([A-Za-z]):\/(.*)$/);
    if (drive) {
      env.HOMEDRIVE = `${drive[1]}:`;
      env.HOMEPATH = `/${drive[2]}`;
    }
  }
  for (const name of [
    'XDG_CONFIG_HOME', 'LOCALAPPDATA', 'GITSETU_TEST_RUNTIME_DIR', 'GIT_CONFIG_GLOBAL'
  ]) {
    if (env[name]) env[name] = normalizeWindowsChildPath(env[name]);
  }
  // The trusted child is Git Bash, not WSL/Linux.  Pin the platform so a
  // host-provided test marker cannot make C:/ paths normalize as POSIX paths.
  env.GITSETU_OS = 'gitbash';
}

function hasReparseComponent(candidate) {
  let current = path.resolve(candidate);
  const root = path.parse(current).root;
  while (current.length > root.length) {
    try {
      if (fs.lstatSync(current).isSymbolicLink()) return true;
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    current = path.dirname(current);
  }
  return false;
}

function isTrustedPackageOwner(stat) {
  if (process.platform === 'win32') return true;
  const currentUid = typeof process.getuid === 'function' ? process.getuid() : null;
  return currentUid !== null && (stat.uid === 0 || stat.uid === currentUid);
}

function assertRegularFile(candidate, label, maxSize = 16 * 1024 * 1024) {
  let stat;
  try { stat = fs.lstatSync(candidate); } catch (error) {
    throw new Error(`${label} is missing`);
  }
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size <= 0 || stat.size > maxSize || !isTrustedPackageOwner(stat)) {
    throw new Error(`${label} is not a bounded regular, non-symlink file`);
  }
  return stat;
}

function assertPathContained(root, candidate) {
  const relative = path.relative(root, candidate);
  if (!relative || path.isAbsolute(relative) || relative.split(/[\\/]+/).includes('..')) {
    throw new Error('package target escapes the package root');
  }
}

function validatePackageContract() {
  // npm's bin shim is legitimately a symlink into the package, and npx invokes
  // the wrapper through exactly that path: node_modules/.bin/gitsetu resolves to
  // node_modules/gitsetu/bin/gitsetu.js. Comparing argv[1]'s parent against
  // rootDir therefore rejected every npx run. Resolve only the final component
  // and require it to land inside the loaded package, while still refusing a
  // symlink at any higher component -- that is the actual redirection case, and
  // it stays rejected because hasReparseComponent(rootDir) already requires the
  // package's own ancestors to be symlink-free.
  const scriptArg = process.argv[1];
  const scriptDir = path.dirname(scriptArg);
  if (hasReparseComponent(scriptDir)) {
    throw new Error('npm wrapper was invoked through a redirected package path');
  }
  let resolvedScript;
  try {
    resolvedScript = fs.realpathSync(scriptArg);
  } catch (error) {
    throw new Error(`npm wrapper entry point could not be resolved: ${error.message}`);
  }
  const invocationRelative = path.relative(rootDir, resolvedScript);
  if (invocationRelative.startsWith('..') || path.isAbsolute(invocationRelative)) {
    throw new Error('npm wrapper was invoked through a redirected package path');
  }
  const rootStat = fs.lstatSync(rootDir);
  if (!rootStat.isDirectory() || rootStat.isSymbolicLink() || !isTrustedPackageOwner(rootStat) || hasReparseComponent(rootDir)) {
    throw new Error('npm package root is redirected or is not a real directory');
  }
  if (fs.existsSync(path.join(rootDir, '.git')) && process.env.GITSETU_NPM_TEST_MODE !== '1') {
    throw new Error('development Git checkout is not an npm package root; use npm pack/install or explicit npm test mode');
  }

  const packagePath = path.join(rootDir, 'package.json');
  assertRegularFile(packagePath, 'npm package manifest', 1024 * 1024);
  assertPathContained(rootDir, packagePath);
  let pkg;
  try { pkg = JSON.parse(fs.readFileSync(packagePath, 'utf8')); } catch (error) {
    throw new Error(`npm package manifest is invalid: ${error.message}`);
  }
  if (pkg.name !== 'gitsetu' || !/^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$/.test(pkg.version || '')) {
    throw new Error('npm package identity is invalid');
  }
  if (pkg.main !== 'bin/gitsetu.js' || !pkg.bin || pkg.bin.gitsetu !== './bin/gitsetu.js' || pkg.bin['git-setu'] !== './bin/gitsetu.js') {
    throw new Error('npm package executable aliases are inconsistent');
  }
  if (!pkg.gitsetuRelease || !['development', 'released'].includes(pkg.gitsetuRelease.state)) {
    throw new Error('npm package release-state contract is missing');
  }

  if (!fs.existsSync(entryScript)) targetScript = bundleScript;
  assertPathContained(rootDir, targetScript);
  assertRegularFile(targetScript, 'GitSetu package target');
  if (hasReparseComponent(targetScript)) throw new Error('GitSetu package target has a symlink/reparse component');

  const libDir = path.join(rootDir, 'lib');
  if (fs.existsSync(libDir)) {
    const libStat = fs.lstatSync(libDir);
    if (!libStat.isDirectory() || libStat.isSymbolicLink()) throw new Error('npm lib directory is redirected');
    for (const name of fs.readdirSync(libDir)) {
      const modulePath = path.join(libDir, name);
      assertPathContained(rootDir, modulePath);
      assertRegularFile(modulePath, `npm library ${name}`);
    }
  }
  return pkg;
}

function trustedPowerShell() {
  const systemDrive = process.env.SystemDrive;
  if (!systemDrive || !/^[A-Za-z]:$/.test(systemDrive)) {
    throw new Error('Windows system drive is invalid');
  }
  const systemRoot = path.join(`${systemDrive}\\`, 'Windows');
  const configuredRoot = process.env.SystemRoot || process.env.windir || '';
  if (!configuredRoot || path.resolve(configuredRoot).toLowerCase() !== path.resolve(systemRoot).toLowerCase()) {
    throw new Error('Windows system root override is not approved');
  }
  const shell = path.join(systemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  if (!fs.existsSync(shell) || hasReparseComponent(shell)) {
    throw new Error('Trusted Windows PowerShell path is unavailable');
  }
  return shell;
}

const trustedBashCheck = `
$ErrorActionPreference = 'Stop'
$p = $env:GITSETU_CANDIDATE_BASH
if (-not $p) { throw 'missing candidate' }
$roots = @(
  (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) 'Git'),
  (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)) 'Git'),
  (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'Programs\\Git')
)
$full = [IO.Path]::GetFullPath($p)
$allowed = $false
foreach ($root in $roots) {
  $prefix = [IO.Path]::GetFullPath($root).TrimEnd('\\') + '\\'
  if ($full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $allowed = $true; break }
}
if (-not $allowed) { throw 'candidate is outside standard Git roots' }
$item = Get-Item -LiteralPath $full -Force
if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'candidate is redirected' }
$current = $item.Directory
while ($null -ne $current) {
  if (($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'candidate has a reparse parent' }
  $current = $current.Parent
}
$acl = Get-Acl -LiteralPath $full
$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$trustedSids = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
$ownerSid = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
if (($ownerSid -notin $trustedSids) -and ($ownerSid -ne $currentSid)) { throw 'candidate owner is untrusted' }
$danger = [Security.AccessControl.FileSystemRights]::WriteData -bor
  [Security.AccessControl.FileSystemRights]::AppendData -bor
  [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
  [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
  [Security.AccessControl.FileSystemRights]::Delete -bor
  [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
  [Security.AccessControl.FileSystemRights]::TakeOwnership
foreach ($rule in $acl.Access) {
  if (($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) -or
      (($rule.FileSystemRights -band $danger) -eq 0)) { continue }
  $ruleSid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
  if (($ruleSid -notin $trustedSids) -and
      ($ruleSid -ne $currentSid)) {
    throw 'candidate has an untrusted write ACL'
  }
}
Write-Output $full
`;

function findTrustedWindowsBash() {
  if (process.env.GITSETU_TEST_MODE === '1' && process.env.GITSETU_TEST_GIT_BASH) {
    const override = path.resolve(process.env.GITSETU_TEST_GIT_BASH);
    if (!path.isAbsolute(override) || path.basename(override).toLowerCase() !== 'bash.exe' || hasReparseComponent(override)) {
      throw new Error('Test Git Bash override is invalid');
    }
    return override;
  }

  const powershell = trustedPowerShell();
  const roots = [
    path.join(process.env.ProgramFiles || 'C:\\Program Files', 'Git'),
    path.join(process.env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)', 'Git'),
    path.join(process.env.LOCALAPPDATA || '', 'Programs', 'Git')
  ];
  const relativeCandidates = ['bin\\bash.exe', 'usr\\bin\\bash.exe'];
  const failures = [];
  for (const root of roots) {
    for (const relative of relativeCandidates) {
      const candidate = path.join(root, relative);
      if (!fs.existsSync(candidate)) continue;
      if (hasReparseComponent(candidate)) {
        failures.push(`${candidate}: reparse-point path component`);
        continue;
      }
      const verified = spawnSync(powershell, [
        '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', trustedBashCheck
      ], {
        encoding: 'utf8',
        windowsHide: true,
        stdio: ['ignore', 'pipe', 'pipe'],
        env: { ...process.env, GITSETU_CANDIDATE_BASH: candidate }
      });
      if (!verified.error && verified.status === 0) {
        return verified.stdout.trim();
      }
      failures.push(`${candidate}: ${(verified.stderr || verified.error?.message || 'verification failed').trim()}`);
    }
  }
  if (failures.length) throw new Error(failures.join('; '));
  return null;
}

let packageContract;
try {
  packageContract = validatePackageContract();
} catch (error) {
  fail(`Untrusted npm package root: ${error.message}`);
}

let shellCommand = '/bin/bash';
let scriptArgument = targetScript;
if (process.platform === 'win32') {
  try {
    shellCommand = findTrustedWindowsBash();
  } catch (error) {
    fail(`Git for Windows trust validation failed: ${error.message}`);
  }
  if (!shellCommand) {
    fail('Git for Windows was not found in a trusted standard installation root. Install the official Git for Windows package.');
  }
  scriptArgument = targetScript.replace(/\\/g, '/');
}

const childEnv = { ...process.env };
for (const untrusted of [
  'GITSETU_BASH', 'GITSETU_TEST_GIT_BASH', 'GITSETU_TEST_BIN', 'GITSETU_TEST_MODE',
  'GITSETU_NPM_TEST_MODE', 'GITSETU_CANDIDATE_BASH', 'GITSETU_DIR', 'GITSETU_SCRIPT_PATH',
  'GITSETU_RUNTIME_MODE', 'GITSETU_PACKAGE_ROOT', 'GITSETU_DISTRIBUTION_CHANNEL'
]) delete childEnv[untrusted];
const normalizedRoot = rootDir.replace(/\\/g, '/');
const normalizedScript = targetScript.replace(/\\/g, '/');
Object.assign(childEnv, {
  GITSETU_DIR: normalizedRoot,
  GITSETU_SCRIPT_PATH: normalizedScript,
  GITSETU_PACKAGE_ROOT: normalizedRoot,
  GITSETU_RUNTIME_MODE: 'verified-npm-package',
  GITSETU_DISTRIBUTION_CHANNEL: 'npm',
  GITSETU_RELEASE_STATE: packageContract.gitsetuRelease.state
});
if (process.platform === 'win32') canonicalizeWindowsChildEnvironment(childEnv);

const child = spawnSync(shellCommand, [scriptArgument, ...process.argv.slice(2)], {
  stdio: 'inherit',
  env: childEnv
});

if (child.error) {
  fail(`Failed to execute GitSetu: ${child.error.message}`);
}
if (child.signal) {
  const signalNumbers = { SIGHUP: 1, SIGINT: 2, SIGQUIT: 3, SIGTERM: 15 };
  process.exit(128 + (signalNumbers[child.signal] || 1));
}
process.exit(child.status === null ? 1 : child.status);
