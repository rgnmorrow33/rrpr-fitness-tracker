#!/usr/bin/env node
/*
 * pre-push-tag-check.js - pre-push tag gate.
 *
 * Blocks a push when a commit about to be pushed references a version (vX.Y)
 * that has no matching git tag. This is the enforcement for CLAUDE.md's "a
 * version is not done until it is tagged" rule, which failed silently for
 * v4.35 (shipped untagged for days).
 *
 * NOTE: this enforces tag-BEFORE-push: create the local tag first
 * (`git tag vX.Y`), push the branch, then push the tag
 * (`git push origin vX.Y`). The tag still marks the exact commit that goes
 * live.
 *
 * Two invocation modes, same check:
 *   (default) Claude Code PreToolUse hook. Reads a tool-call JSON on stdin,
 *     acts only when the command is a `git ... push`. exit 0 = allow,
 *     exit 2 = BLOCK (stderr fed back to Claude), exit 1 = non-blocking error.
 *   (--git)   Native git pre-push hook (githooks/pre-push). git guarantees a
 *     push is happening, so stdin and the isGitPush gate are skipped (the git
 *     pre-push refspec lines on stdin are intentionally ignored - the range
 *     logic below is reused instead). git treats ANY nonzero exit as a block,
 *     so a detected problem exits 1 and an unexpected internal error fails
 *     OPEN with exit 0. No logic is duplicated between the two modes.
 *
 * Range checked: upstream (origin/<branch> if it exists, else origin/main)
 * ..HEAD - i.e. the commits this push would publish.
 */

'use strict';

const fs = require('fs');
const { spawnSync } = require('child_process');

// --git = native git pre-push hook; default = Claude Code PreToolUse hook.
const GIT_MODE = process.argv.includes('--git');
// git blocks on any nonzero, so block=1 there; Claude hooks block on 2.
const BLOCK = GIT_MODE ? 1 : 2;

function readStdin() {
  try {
    return fs.readFileSync(0, 'utf8');
  } catch (e) {
    return '';
  }
}

function git(args, cwd) {
  return spawnSync('git', args, { cwd, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
}

function projectRoot() {
  if (process.env.CLAUDE_PROJECT_DIR) return process.env.CLAUDE_PROJECT_DIR;
  const r = git(['rev-parse', '--show-toplevel']);
  if (r.status === 0) return r.stdout.trim();
  return process.cwd();
}

function isGitPush(command) {
  return /\bgit(\.exe)?["']?\s+(-[^\s]+\s+|-C\s+\S+\s+)*push\b/i.test(command);
}

function main() {
  // In git mode the push is already happening; skip the stdin/command gate.
  if (!GIT_MODE) {
    let input = {};
    try {
      input = JSON.parse(readStdin() || '{}');
    } catch (e) {
      process.exit(0);
    }
    const command = (input.tool_input && input.tool_input.command) || '';
    if (!isGitPush(command)) process.exit(0);
  }

  const root = projectRoot();

  const branchRes = git(['rev-parse', '--abbrev-ref', 'HEAD'], root);
  if (branchRes.status !== 0) process.exit(0);
  const branch = branchRes.stdout.trim();

  // Base = what origin already has: origin/<branch> if it exists, else
  // origin/main (new branch - everything since main is "being pushed").
  let base = null;
  for (const candidate of [`origin/${branch}`, 'origin/main']) {
    if (git(['rev-parse', '--verify', '--quiet', `${candidate}^{commit}`], root).status === 0) {
      base = candidate;
      break;
    }
  }
  if (!base) process.exit(0); // no origin refs - nothing sensible to gate

  const log = git(['log', '--format=%B', `${base}..HEAD`], root);
  if (log.status !== 0) process.exit(0);

  const versions = new Set();
  const re = /\bv\d+\.\d+\b/g;
  let m;
  while ((m = re.exec(log.stdout)) !== null) versions.add(m[0]);
  if (versions.size === 0) process.exit(0);

  const untagged = [];
  for (const v of versions) {
    const tag = git(['tag', '--list', v], root);
    if (tag.status !== 0 || tag.stdout.trim() === '') untagged.push(v);
  }

  if (untagged.length > 0) {
    process.stderr.write(
      `BLOCKED: commit(s) in ${base}..HEAD reference version(s) with no git tag: ` +
      `${untagged.join(', ')}.\n` +
      `A version is not done until it is tagged (CLAUDE.md). Create the tag ` +
      `first, then push, then push the tag:\n` +
      untagged.map((v) => `  git tag ${v}`).join('\n') + '\n' +
      `  git push\n` +
      untagged.map((v) => `  git push origin ${v}`).join('\n') + '\n'
    );
    process.exit(BLOCK);
  }
  process.exit(0);
}

try {
  main();
} catch (e) {
  // Fail OPEN so a guard bug never freezes pushes. git mode: nonzero would
  // block, so exit 0; Claude mode: exit 1 is the non-blocking-error code.
  process.stderr.write(`pre-push-tag-check hook error (push NOT blocked): ${e.message}\n`);
  process.exit(GIT_MODE ? 0 : 1);
}
