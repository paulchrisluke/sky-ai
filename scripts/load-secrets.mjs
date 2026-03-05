#!/usr/bin/env node
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';

const secretFile = process.argv[2] || '.secrets.local';

if (!fs.existsSync(secretFile)) {
  console.error(`Secret file not found: ${secretFile}`);
  process.exit(1);
}

const text = fs.readFileSync(secretFile, 'utf8');
const secrets = {};

text.split(/\r?\n/).forEach((line) => {
  const trimmed = line.trim();
  if (!trimmed || trimmed.startsWith('#')) return;

  const idx = trimmed.indexOf('=');
  if (idx <= 0) return;

  const key = trimmed.slice(0, idx).trim();
  const value = trimmed.slice(idx + 1).trim();
  if (!key || !value) return;
  secrets[key] = value;
});

if (!Object.keys(secrets).length) {
  console.error('No KEY=VALUE pairs found in secret file.');
  process.exit(1);
}

const run = spawnSync(
  'npx',
  ['clasp', 'run', 'setSecretsFromLocal', '--params', JSON.stringify([secrets])],
  { stdio: 'inherit' }
);

process.exit(run.status === null ? 1 : run.status);
