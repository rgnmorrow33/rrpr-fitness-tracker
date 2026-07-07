#!/usr/bin/env node
/*
 * pre-push-syntax-check.js - Claude Code PreToolUse hook.
 *
 * Blocks any `git push` issued through Claude Code if the embedded JS in
 * RoundRock_Fitness_Tracker.html (as of HEAD - the content the push would
 * ship) fails `node --check`. Closes the gap where CI (smoke.yml) only runs
 * post-deploy, so a syntax error would otherwise reach production iPads
 * before anything automated notices.
 *
 * Contract (Claude Code hooks):
 *   stdin: JSON {tool_name, tool_input: {command, ...}, ...}
 *   exit 0 = allow, exit 2 = BLOCK (stderr is fed back to Claude),
 *   exit 1 = non-blocking error (stderr shown to user only).
 *
 * Scope: only acts when the command being run contains a `git ... push`.
 * Checks HEAD of the current branch; refspec parsing is deliberately not
 * attempted (pushing a ref other than HEAD is not this repo's flow).
 *
 * Fail-open on its own unexpected errors (exit 1): a bug in this guard must
 * not freeze all pushes.
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const HTML_FILE = 'RoundRock_Fitness_Tracker.html';

function readStdin() {
  try {
    return fs.readFileSync(0, 'utf8');
  } catch (e) {
    return '';
  }
}

function projectRoot() {
  if (process.env.CLAUDE_PROJECT_DIR) return process.env.CLAUDE_PROJECT_DIR;
  const r = spawnSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' });
  if (r.status === 0) return r.stdout.trim();
  return process.cwd();
}

function isGitPush(command) {
  // `git push`, `git -C dir push`, `& git.exe push`, `$git push` etc.
  return /\bgit(\.exe)?["']?\s+(-[^\s]+\s+|-C\s+\S+\s+)*push\b/i.test(command);
}

function main() {
  let input = {};
  try {
    input = JSON.parse(readStdin() || '{}');
  } catch (e) {
    process.exit(0); // unparseable stdin - not a tool call we understand
  }
  const command = (input.tool_input && input.tool_input.command) || '';
  if (!isGitPush(command)) process.exit(0);

  const root = projectRoot();

  // Content the push would ship: HEAD's version of the file.
  const show = spawnSync('git', ['show', `HEAD:${HTML_FILE}`], {
    cwd: root,
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
  });
  if (show.status !== 0) {
    process.stderr.write(
      `BLOCKED: ${HTML_FILE} not found at HEAD. The tracker file must not be ` +
      `renamed or removed (netlify.toml serves it at the root URL). If this is ` +
      `intentional, bypass by disabling the pre-push-syntax-check hook.\n`
    );
    process.exit(2);
  }

  // Extract every inline <script> block (no src attribute). Pad with newlines
  // so node --check reports real HTML line numbers.
  const html = show.stdout;
  const blocks = [];
  const re = /<script\b([^>]*)>([\s\S]*?)<\/script>/gi;
  let m;
  while ((m = re.exec(html)) !== null) {
    if (/\bsrc\s*=/i.test(m[1])) continue;
    const lineOffset = html.slice(0, m.index).split('\n').length; // 1-based line of <script>
    blocks.push({ lineOffset, code: m[2] });
  }
  if (blocks.length === 0) {
    process.stderr.write(
      `BLOCKED: no inline <script> block found in ${HTML_FILE} at HEAD. ` +
      `The app's embedded JS is missing - refusing to push.\n`
    );
    process.exit(2);
  }

  const failures = [];
  for (const b of blocks) {
    // Block content begins on the <script> tag's own line (the tag's trailing
    // newline is part of the captured code), so pad to lineOffset - 1.
    const padded = '\n'.repeat(b.lineOffset - 1) + b.code;
    const tmp = path.join(os.tmpdir(), `rrpr-embedded-check-${process.pid}.js`);
    fs.writeFileSync(tmp, padded, 'utf8');
    const check = spawnSync(process.execPath, ['--check', tmp], { encoding: 'utf8' });
    try { fs.unlinkSync(tmp); } catch (e) { /* temp cleanup is best-effort */ }
    if (check.status !== 0) {
      failures.push((check.stderr || 'node --check failed').replace(new RegExp(tmp.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'g'), `${HTML_FILE} (embedded JS)`));
    }
  }

  if (failures.length > 0) {
    process.stderr.write(
      `BLOCKED: node --check failed on the embedded JS in ${HTML_FILE} at HEAD. ` +
      `Fix the syntax error and amend/re-commit before pushing. Line numbers ` +
      `below match the HTML file.\n\n` + failures.join('\n') + '\n'
    );
    process.exit(2);
  }
  process.exit(0);
}

try {
  main();
} catch (e) {
  process.stderr.write(`pre-push-syntax-check hook error (push NOT blocked): ${e.message}\n`);
  process.exit(1);
}
