#!/usr/bin/env node
'use strict';

const { spawnSync } = require('child_process');
const path = require('path');
const fs = require('fs');

const rootDir = path.resolve(__dirname, '..');
const gitsetuScript = path.join(rootDir, 'gitsetu');

function findWindowsBash() {
  if (process.env.GITSETU_BASH && fs.existsSync(process.env.GITSETU_BASH)) {
    return process.env.GITSETU_BASH;
  }

  // 1. Check PATH via where.exe
  try {
    const res = spawnSync('where.exe', ['bash.exe'], { encoding: 'utf8', stdio: ['pipe', 'pipe', 'ignore'] });
    if (res.status === 0 && res.stdout) {
      const lines = res.stdout.trim().split(/\r?\n/).map(l => l.trim()).filter(Boolean);
      for (const line of lines) {
        if (line.toLowerCase().includes('git') && fs.existsSync(line)) {
          return line;
        }
      }
      if (lines[0] && fs.existsSync(lines[0])) {
        return lines[0];
      }
    }
  } catch (e) {
    // Ignore error and try other paths
  }

  // 2. Standard Git for Windows installation directories
  const programFiles = process.env['ProgramFiles'] || 'C:\\Program Files';
  const programFilesX86 = process.env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)';
  const localAppData = process.env['LOCALAPPDATA'] || '';
  const programData = process.env['ProgramData'] || 'C:\\ProgramData';

  const standardPaths = [
    path.join(programFiles, 'Git', 'bin', 'bash.exe'),
    path.join(programFiles, 'Git', 'usr', 'bin', 'bash.exe'),
    path.join(programFilesX86, 'Git', 'bin', 'bash.exe'),
    path.join(programFilesX86, 'Git', 'usr', 'bin', 'bash.exe'),
    path.join(localAppData, 'Programs', 'Git', 'bin', 'bash.exe'),
    path.join(programData, 'chocolatey', 'bin', 'bash.exe'),
    path.join(localAppData, 'gitsetu', 'bin', 'bash.exe')
  ];

  for (const p of standardPaths) {
    if (fs.existsSync(p)) {
      return p;
    }
  }

  // 3. Query git --exec-path
  try {
    const res = spawnSync('git', ['--exec-path'], { encoding: 'utf8', stdio: ['pipe', 'pipe', 'ignore'] });
    if (res.status === 0 && res.stdout) {
      const execPath = res.stdout.trim();
      const candidate1 = path.resolve(execPath, '..', '..', 'bin', 'bash.exe');
      if (fs.existsSync(candidate1)) {
        return candidate1;
      }
      const candidate2 = path.resolve(execPath, '..', '..', 'usr', 'bin', 'bash.exe');
      if (fs.existsSync(candidate2)) {
        return candidate2;
      }
    }
  } catch (e) {
    // Ignore
  }

  return null;
}

let targetScript = gitsetuScript;
if (!fs.existsSync(targetScript)) {
  const distScript = path.join(rootDir, 'dist', 'gitsetu');
  if (fs.existsSync(distScript)) {
    targetScript = distScript;
  } else {
    console.error(`\x1b[31m[Error]\x1b[0m GitSetu executable not found at: ${gitsetuScript}`);
    process.exit(1);
  }
}

const args = process.argv.slice(2);
let shellCmd = 'bash';
let spawnArgs = [targetScript, ...args];

if (process.platform === 'win32') {
  const bashExe = findWindowsBash();
  if (!bashExe) {
    console.error('\x1b[31m[Error]\x1b[0m Git for Windows (bash.exe) was not found.');
    console.error('GitSetu requires Git for Windows. Please install Git:');
    console.error('  - Download: https://git-scm.com/download/win');
    console.error('  - Or run: winget install Git.Git');
    process.exit(1);
  }
  shellCmd = bashExe;
}

const child = spawnSync(shellCmd, spawnArgs, {
  stdio: 'inherit',
  env: process.env
});

if (child.error) {
  console.error(`\x1b[31m[Error]\x1b[0m Failed to execute GitSetu: ${child.error.message}`);
  process.exit(1);
}

process.exit(child.status !== null ? child.status : 0);
