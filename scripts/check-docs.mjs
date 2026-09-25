#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = (relative) => fs.readFileSync(path.join(root, relative), 'utf8');
const release = JSON.parse(read('packaging/release.json'));
const development = release.release?.state === 'development';
const released = release.release?.state === 'released';
const failures = [];

const currentDocs = [
  'README.md',
  'SECURITY.md',
  'packaging/README.md',
  'CHANGELOG.md',
  'docs/getting-started/installation.md',
  'docs/reference/cli-commands.md',
  'docs/enterprise/product-roadmap.md',
  'docs/enterprise/security-privacy.md',
  'docs/reference/manual-qa.md',
  'docs/reference/troubleshooting.md',
  'sandbox/README.md'
];

if (!development && !released) {
  failures.push(`unsupported release state: ${release.release?.state}`);
}

const changelog = read('CHANGELOG.md');
const changelogHeading = changelog.match(/^## \[[^\n]+\]/m)?.[0] || '';
if (development) {
  if (!/^## \[1\.1\.0 — Verified release candidate \(unpublished\)\]/.test(changelogHeading)) {
    failures.push(`candidate changelog heading is not explicit: ${changelogHeading || 'missing'}`);
  }
  if (/^## \[Unreleased/m.test(changelog)) {
    failures.push('active changelog section still uses an ambiguous Unreleased heading');
  }
  for (const file of ['README.md', 'SECURITY.md', 'packaging/README.md', 'docs/getting-started/installation.md', 'docs/reference/cli-commands.md']) {
    const text = read(file);
    if (!/(release candidate|unpublished|not (?:yet )?a public release)/i.test(text)) {
      failures.push(`${file} does not state the current unpublished candidate status`);
    }
  }
  if (/download(?:ed|ing)? a published release artifact/i.test(read('docs/getting-started/installation.md'))) {
    failures.push('installation guide implies a public v1.1.0 artifact exists before publication');
  }
  if (/Baseline GA Release/i.test(read('docs/enterprise/product-roadmap.md'))) {
    failures.push('product roadmap still calls the candidate baseline a GA release');
  }
  if (/gitsetu init --auto/i.test(read('docs/enterprise/product-roadmap.md'))) {
    failures.push('product roadmap uses the stale gitsetu init --auto command');
  }
  const troubleshooting = read('docs/reference/troubleshooting.md');
  if (/(?:can|may|utilize|use).{0,80}(?:--no-verify|git commit -n).{0,80}(?:bypass|guard|identity)/i.test(troubleshooting)) {
    failures.push('troubleshooting guide recommends bypassing the identity guard');
  }
} else if (released) {
  if (!/^## \[1\.1\.0\] - \d{4}-\d{2}-\d{2}$/.test(changelogHeading)) {
    failures.push(`released changelog heading is not dated: ${changelogHeading || 'missing'}`);
  }
  for (const file of ['README.md', 'SECURITY.md', 'packaging/README.md', 'docs/getting-started/installation.md', 'docs/reference/cli-commands.md']) {
    if (/not (?:yet )?a public release|unpublished/i.test(read(file))) {
      failures.push(`${file} still describes the published release as unpublished`);
    }
  }
}

function collectMarkdown(relativeDirectory) {
  const directory = path.join(root, relativeDirectory);
  if (!fs.existsSync(directory)) return [];
  const files = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const relative = path.join(relativeDirectory, entry.name).replaceAll(path.sep, '/');
    if (entry.isDirectory()) files.push(...collectMarkdown(relative));
    else if (entry.isFile() && entry.name.endsWith('.md')) files.push(relative);
  }
  return files;
}

const allDocs = [...new Set([
  ...currentDocs,
  ...collectMarkdown('docs')
])];
for (const file of allDocs) {
  const text = read(file);
  if (/raw\.githubusercontent\.com\/[^\s)]+\/(?:main|master)\//i.test(text)) {
    failures.push(`${file} contains a mutable raw GitHub documentation URL`);
  }
}

if (failures.length) {
  console.error('Documentation consistency: FAIL');
  for (const failure of failures) console.error(` - ${failure}`);
  process.exit(1);
}

console.log(`Documentation consistency: PASS (${development ? 'development candidate' : 'released'}, ${allDocs.length} files checked)`);
