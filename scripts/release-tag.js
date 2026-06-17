#!/usr/bin/env node
/*
 * release-tag.js - tag a release, then scaffold the update-log for it.
 *
 * Does the two closing acts of a release in one command:
 *   1. tag the current HEAD as the new version (vX.Y), and
 *   2. emit the update-log scaffold for the range since the PREVIOUS version
 *      tag, ready to paste into a Claude session.
 *
 * Usage:
 *   npm run release:tag -- v4.32            tag HEAD as v4.32 (LOCAL only)
 *   npm run release:tag -- v4.32 --push     also push the tag to origin
 *   npm run release:tag -- v4.32 --allow-dirty   tag despite a dirty tree
 *
 * BOUNDARIES (by design):
 *   - The ONLY writes this tool performs are: create a local git tag, and
 *     - only with --push - push that tag to origin. Nothing else. No commits,
 *     no merges, no branch changes, no file writes, no docx, no docs.
 *   - Pushing is OPT-IN. Default leaves the tag local so a mistyped version
 *     never reaches origin; the exact push command is printed for you to run.
 *   - The scaffold half is read-only and reuses scripts/log-scaffold.js.
 */

'use strict';

const { execFileSync } = require('child_process');
const scaffold = require('./log-scaffold.js');

const VERSION_RE = /^v\d+\.\d+$/;

function git(args, opts) {
  return execFileSync('git', args, {
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
    ...opts,
  });
}

function gitQuiet(args) {
  try {
    return git(args, { stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch (e) {
    return '';
  }
}

// stderr so stdout stays purely the scaffold (pipeable / redirectable).
function info(msg) {
  process.stderr.write(msg + '\n');
}

function die(msg, code) {
  process.stderr.write(msg + '\n');
  process.exit(code == null ? 1 : code);
}

function main() {
  const argv = process.argv.slice(2);
  const push = argv.includes('--push');
  const allowDirty = argv.includes('--allow-dirty');
  const positionals = argv.filter((a) => !a.startsWith('--'));
  const version = positionals[0];

  // Must be in a git work tree.
  if (gitQuiet(['rev-parse', '--is-inside-work-tree']) !== 'true') {
    die('error: not inside a git repository.');
  }

  // 1. Validate the version arg shape.
  if (!version) {
    die('error: missing version.\nUsage: npm run release:tag -- vX.Y [--push] [--allow-dirty]');
  }
  if (!VERSION_RE.test(version)) {
    die(
      'error: version "' + version + '" must match vX.Y (e.g. v4.32).\n' +
      'Rejected so a mistyped version (4.32, v4.32.0, V4.32) never becomes a tag.'
    );
  }

  // 2. Refuse if the tag already exists - locally or on origin. No clobbering.
  const localTagSha = gitQuiet(['rev-parse', '--verify', '--quiet', 'refs/tags/' + version]);
  if (localTagSha) {
    die(
      'error: tag ' + version + ' already exists locally at ' +
      gitQuiet(['rev-parse', '--short', localTagSha]) + '. Not clobbering.'
    );
  }
  // Remote check needs the network; tolerate it being unreachable.
  let remoteChecked = false;
  try {
    const remote = git(['ls-remote', '--tags', 'origin', 'refs/tags/' + version], {
      stdio: ['ignore', 'pipe', 'pipe'],
    }).trim();
    remoteChecked = true;
    if (remote) {
      die(
        'error: tag ' + version + ' already exists on origin:\n  ' +
        remote.split('\n')[0] + '\nNot clobbering.'
      );
    }
  } catch (e) {
    info('note: could not reach origin to check for an existing remote tag; checked locally only.');
  }

  // 3. Refuse on a dirty working tree (unless explicitly overridden).
  const dirty = gitQuiet(['status', '--porcelain']);
  if (dirty && !allowDirty) {
    die(
      'error: working tree is dirty. A version tag must mark a clean, pushed state.\n' +
      'Commit or stash first, or re-run with --allow-dirty to override.\n\n' +
      git(['status', '--short'])
    );
  }
  if (dirty && allowDirty) {
    info('warning: --allow-dirty set; tagging despite uncommitted changes.');
  }

  // Convention (CLAUDE.md): tag AFTER the version's commits are pushed to main.
  // Soft warning only - the spec mandates refusing on dirty, not on un-pushed,
  // and this is judged against the last-fetched origin/main (may be stale).
  const originMain = gitQuiet(['rev-parse', '--verify', '--quiet', 'origin/main']);
  if (originMain) {
    // merge-base --is-ancestor exits 0 if HEAD is on origin/main, non-zero otherwise.
    try {
      git(['merge-base', '--is-ancestor', 'HEAD', 'origin/main'], { stdio: 'ignore' });
    } catch (e) {
      info('warning: HEAD is not on origin/main (per last fetch). Convention is to');
      info('         tag a pushed commit - push main first, or fetch if stale.');
    }
  }

  // 4. Find the PREVIOUS version tag (highest vX.Y, the new one cannot exist yet).
  const allTags = gitQuiet(['tag', '--list', 'v*', '--sort=-v:refname'])
    .split('\n')
    .map((t) => t.trim())
    .filter((t) => VERSION_RE.test(t) && t !== version);
  const prevTag = allTags[0] || null;

  // 5. Create the lightweight tag at HEAD (no -a, no -m, no signing).
  const headShort = gitQuiet(['rev-parse', '--short', 'HEAD']);
  git(['tag', version]);
  info('tagged ' + version + ' at ' + headShort + ' (local).');

  // 6. Push only when asked; otherwise print the exact command.
  if (push) {
    try {
      git(['push', 'origin', version], { stdio: ['ignore', 'pipe', 'pipe'] });
      info('pushed ' + version + ' to origin.');
    } catch (e) {
      info('error: push failed. The local tag still exists. Push it yourself with:');
      info('  git push origin ' + version);
      info(String(e.stderr || e.message || e).trim());
    }
  } else {
    info('not pushed (default). When ready, run:');
    info('  git push origin ' + version);
  }

  // 7. Emit the update-log scaffold for prevTag..HEAD by reusing log-scaffold.js.
  if (prevTag) {
    info('scaffold below covers ' + prevTag + '..HEAD.');
    info('');
    process.stdout.write(scaffold.generateScaffold(prevTag));
  } else {
    info('no previous version tag found - this is the first release.');
    info('scaffold below covers the full history up to HEAD.');
    info('');
    process.stdout.write(
      scaffold.generateScaffoldFromBase({
        base: scaffold.EMPTY_TREE,
        kind: 'root',
        label: '(start of history)',
      })
    );
  }
}

main();
