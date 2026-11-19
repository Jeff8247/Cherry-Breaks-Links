#!/usr/bin/env node
// Cross-platform (Windows / macOS / Linux) browser fetch helper.
//
// Loads a URL in a real Chromium/Chrome via Playwright so Cloudflare's
// JavaScript challenge can complete, then prints one JSON object to stdout:
//   { "status": 200, "body": "<page text>", "challenged": false }
//
// Usage: node browser-fetch.mjs <url> [--headed] [--profile <dir>] [--timeout <sec>]
//
// A persistent profile keeps the Cloudflare clearance cookie between runs, so
// the challenge usually only has to be solved once in a while.

import { chromium } from 'playwright-core';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const args = process.argv.slice(2);
const url = args.find((a) => /^https?:\/\//.test(a));
const opt = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
};
const headed = args.includes('--headed');
const profile = opt('--profile', join(import.meta.dirname, '.browser-profile'));
const timeoutMs = Number(opt('--timeout', '60')) * 1000;

// Never call process.exit() after writing to stdout: on a pipe the write is async on
// POSIX and exit() truncates large payloads. Set exitCode and let the process drain.
function emit(result, code) {
  process.stdout.write(JSON.stringify(result));
  process.exitCode = code;
}

function fail(message, code = 2) {
  emit({ status: 0, body: '', challenged: false, error: message }, code);
}

const isChallenge = (title) => /Verifying|Just a moment|Attention Required/i.test(title || '');

// Prefer the user's installed Chrome/Edge (best chance with Cloudflare, no download
// needed on Windows/macOS); fall back to Playwright's bundled Chromium.
async function launch() {
  const base = { headless: !headed, args: ['--no-sandbox'] };
  const attempts = [{ channel: 'chrome' }, { channel: 'msedge' }, {}];
  let lastError;
  for (const extra of attempts) {
    try {
      return await chromium.launchPersistentContext(profile, { ...base, ...extra });
    } catch (e) {
      lastError = e;
    }
  }
  throw lastError;
}

let context;
try {
  if (!url) throw new Error('Usage: node browser-fetch.mjs <url> [--headed] [--profile <dir>] [--timeout <sec>]');
  context = await launch();
  const page = context.pages()[0] ?? (await context.newPage());

  const response = await page.goto(url, { waitUntil: 'domcontentloaded', timeout: timeoutMs });
  let status = response ? response.status() : 0;

  // Wait for the challenge interstitial to resolve itself.
  const deadline = Date.now() + timeoutMs;
  let challenged = isChallenge(await page.title());
  while (challenged && Date.now() < deadline) {
    await page.waitForTimeout(2000);
    challenged = isChallenge(await page.title().catch(() => ''));
  }

  if (!challenged && status === 403) {
    // The challenge passed and the page reloaded; re-read the final response.
    const again = await page.goto(url, { waitUntil: 'domcontentloaded', timeout: timeoutMs });
    status = again ? again.status() : status;
  }

  const body = challenged ? '' : await page.evaluate(() => document.body.innerText);
  emit({ status, body, challenged }, challenged ? 3 : 0);
} catch (e) {
  fail(String(e.message ?? e).split('\n')[0], 1);
} finally {
  if (context) await context.close().catch(() => {});
}
