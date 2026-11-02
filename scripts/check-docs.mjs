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
  'CONTRIBUTING.md',
  'CODE_OF_CONDUCT.md',
  '.github/PULL_REQUEST_TEMPLATE.md',
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
const changelogHeading = changelog.match(/^## \[[^\n]+/m)?.[0] || '';
if (!/^## \[1\.1\.0\] - \d{4}-\d{2}-\d{2}$/.test(changelogHeading)) {
  failures.push(`changelog heading is not dated [1.1.0]: ${changelogHeading || 'missing'}`);
}
if (/^## \[Unreleased/m.test(changelog)) {
  failures.push('active changelog section still uses an ambiguous Unreleased heading');
}

for (const file of currentDocs) {
  const text = read(file);
  if (/publication-ready|verified\s+(?:\w+\s+)*release candidate/i.test(text)) {
    failures.push(`${file} contains forbidden release candidate wording`);
  }
}

const readmeText = read('README.md');
if (!/https:\/\/github\.com\/bhaskarjha-dev\/gitsetu\/releases/i.test(readmeText)) {
  failures.push('README.md quick start does not reference the GitHub Releases URL');
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
if (released) {
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
