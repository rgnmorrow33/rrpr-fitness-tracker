#!/usr/bin/env node
/*
 * pre-push-tag-check.js - Claude Code PreToolUse hook.
 *
 * Blocks any `git push` issued through Claude Code when a commit about to be
 * pushed references a version (vX.Y) that has no matching git tag. This is
 * the enforcement for CLAUDE.md's "a version is not done until it is tagged"
 * rule, which failed silently for v4.35 (shipped untagged for days).
 *
 * NOTE: this shifts the tagging convention from tag-AFTER-push to
 * tag-BEFORE-push: create the local tag first (`git tag vX.Y`), push the
 * branch, then push the tag (`git push origin vX.Y`). The tag still marks the
 * exact commit that goes live.
 *
 * Contract (Claude Code hooks):
 *   stdin: JSON {tool_name, tool_input: {command, ...}, ...}
 *   exit 0 = allow, exit 2 = BLOCK (stderr fed back to Claude),
 *   exit 1 = non-blocking error (stderr shown to user only).
 *
 * Range checked: upstream (origin/<branch> if it exists, else origin/main)
 * ..HEAD - i.e. the commits this push would publish. Fail-open on unexpected
 * errors.
 */

'use strict';

const fs = require('fs');
const { spawnSync } = require('child_process');

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
  let input = {};
  try {
    input = JSON.parse(readStdin() || '{}');
  } catch (e) {
    process.exit(0);
  }
  const command = (input.tool_input && input.tool_input.command) || '';
  if (!isGitPush(command)) process.exit(0);

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
    process.exit(2);
  }
  process.exit(0);
}

try {
  main();
} catch (e) {
  process.stderr.write(`pre-push-tag-check hook error (push NOT blocked): ${e.message}\n`);
  process.exit(1);
}
