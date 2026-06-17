#!/usr/bin/env node
/*
 * log-scaffold.js - update-log scaffold helper
 *
 * Removes the mechanical toil of writing an update-log entry: digs up the
 * commit SHAs, per-commit and aggregate diff stats, and the changed-file list
 * since the last logged version. Prints a plain-text scaffold to stdout with
 * the fitness-tracker-update-log skill's section headers, where File version
 * is pre-filled and the narrative sections are left as TODO lines for a human
 * (or Claude) to fill in.
 *
 * It scaffolds, it does not write the log.
 *
 * Usage:
 *   npm run log:scaffold -- <last-version-ref>
 *     <last-version-ref> may be a tag, a commit SHA, or a date
 *     (e.g. v4.31, ba8e24b, 2026-06-01, "2 weeks ago").
 *   If no ref is given, defaults to the most recent git tag.
 *
 * HARD BOUNDARIES (by design):
 *   - Read-only against git. No commits, tags, pushes, or working-tree writes.
 *   - Writes only to stdout. Does NOT touch the docx and does NOT write docs/.
 *     Redirect to a scratch file yourself if you want one:
 *       npm run log:scaffold -- v4.31 > scratch-log.txt
 */

'use strict';

const { execFileSync } = require('child_process');

const EMPTY_TREE = '4b825dc642cb6eb9a060e54bf8d69288fbee4904';

function git(args, opts) {
  return execFileSync('git', args, {
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
    ...opts,
  });
}

// git that returns '' instead of throwing (for probes that are allowed to fail).
function gitQuiet(args) {
  try {
    return git(args, { stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch (e) {
    return '';
  }
}

function die(msg, code) {
  process.stderr.write(msg + '\n');
  process.exit(code == null ? 1 : code);
}

// Resolve the user-supplied ref into a base commit-ish we can diff HEAD against.
// Returns { base, kind, label }:
//   kind 'ref'  -> ref was a tag/SHA; base is that commit.
//   kind 'date' -> ref was treated as a date; base is the last commit before it
//                  (or the empty tree if the date predates all history).
function resolveBase(ref) {
  // Is it a commit-ish (tag or SHA)?
  const sha = gitQuiet(['rev-parse', '--verify', '--quiet', ref + '^{commit}']);
  if (sha) {
    return { base: sha, kind: 'ref', label: ref };
  }

  // Otherwise treat it as a date. git's date parser is lenient, so warn loudly
  // that we did NOT find a tag/SHA by this name and fell back to a date window.
  process.stderr.write(
    'note: "' + ref + '" is not a tag or commit; treating it as a date.\n'
  );
  const before = gitQuiet(['rev-list', '-1', '--before=' + ref, 'HEAD']);
  if (before) {
    return { base: before, kind: 'date', label: ref };
  }
  // Date predates the first commit -> diff from the empty tree (all history).
  return { base: EMPTY_TREE, kind: 'date', label: ref };
}

function shortStatLine(range) {
  // " N files changed, A insertions(+), B deletions(-)" or '' if no change.
  const out = gitQuiet(['diff', '--shortstat', range]);
  return out || '(no changes)';
}

// Per-commit list: short SHA, subject, and that commit's +X/-Y.
function commitList(base) {
  const range = base + '..HEAD';
  const SEP = '\x1f'; // unit separator, safe inside subjects
  // One record per commit; --shortstat appends the stat line(s) after each.
  const raw = gitQuiet([
    'log',
    range,
    '--shortstat',
    '--date=short',
    '--pretty=format:@@C@@%h' + SEP + '%ad' + SEP + '%s',
  ]);
  if (!raw) return [];

  const commits = [];
  let cur = null;
  for (const line of raw.split('\n')) {
    if (line.startsWith('@@C@@')) {
      if (cur) commits.push(cur);
      const [h, d, s] = line.slice('@@C@@'.length).split(SEP);
      cur = { sha: h, date: d, subject: s, ins: 0, del: 0, files: 0 };
    } else if (cur && /files? changed/.test(line)) {
      const f = line.match(/(\d+) files? changed/);
      const i = line.match(/(\d+) insertions?\(\+\)/);
      const dd = line.match(/(\d+) deletions?\(-\)/);
      cur.files = f ? +f[1] : 0;
      cur.ins = i ? +i[1] : 0;
      cur.del = dd ? +dd[1] : 0;
    }
  }
  if (cur) commits.push(cur);
  return commits;
}

function changedFiles(base) {
  const out = gitQuiet(['diff', '--name-only', base + '..HEAD']);
  return out ? out.split('\n').filter(Boolean) : [];
}

// Build the full scaffold text for a ref (tag/SHA/date). Returns a string;
// does not write anything. Used by both this CLI and release-tag.js.
function generateScaffold(ref) {
  return generateScaffoldFromBase(resolveBase(ref));
}

// Same as generateScaffold but takes an already-resolved base descriptor
// { base, kind, label }. release-tag.js uses this directly for the first-ever
// release (base = EMPTY_TREE, kind = 'root'), where there is no previous tag.
function generateScaffoldFromBase(baseInfo) {
  const { base, kind, label } = baseInfo;
  const tagCount = gitQuiet(['tag']).split('\n').filter(Boolean).length;
  const kindSuffix =
    kind === 'date' ? '  (interpreted as a date)' : kind === 'root' ? '' : '  (tag/SHA)';
  const headSha = gitQuiet(['rev-parse', '--short', 'HEAD']);
  const headFull = gitQuiet(['rev-parse', 'HEAD']);
  const baseShort = base === EMPTY_TREE ? '(empty tree / all history)' : gitQuiet(['rev-parse', '--short', base]);
  const range = base + '..HEAD';

  const commits = commitList(base);
  const aggregate = shortStatLine(range);
  const files = changedFiles(base);

  const APP = 'RoundRock_Fitness_Tracker.html';
  const appChanged = files.includes(APP);
  const docsChanged = files.some((f) => f.startsWith('docs/'));
  const ghChanged = files.some((f) => f.startsWith('.github/'));
  const scriptsChanged = files.some((f) => f.startsWith('scripts/'));

  const out = [];
  const p = (s) => out.push(s == null ? '' : s);

  p('================================================================');
  p(' UPDATE-LOG SCAFFOLD  (raw material - not the log itself)');
  p('================================================================');
  p('Generated by scripts/log-scaffold.js. Read-only; nothing was written');
  p('to git, the docx, or docs/. Drop the skeleton below into a Claude');
  p('session and write the entry with the fitness-tracker-update-log skill.');
  p('');
  p('Since ref : ' + label + kindSuffix);
  p('Base      : ' + baseShort);
  p('HEAD      : ' + headSha + '  (' + headFull + ')');
  p('Range     : ' + range);
  p('Commits   : ' + commits.length);
  p('');

  p('----------------------------------------------------------------');
  p(' COMMITS SINCE ' + label + '  (oldest first)');
  p('----------------------------------------------------------------');
  if (commits.length === 0) {
    p('(none - HEAD is at or behind the given ref)');
  } else {
    // Oldest-first reads naturally as a changelog; git log is newest-first.
    for (const c of commits.slice().reverse()) {
      p(c.sha + '  ' + c.date + '  +' + c.ins + '/-' + c.del + '  ' + c.subject);
    }
  }
  p('');

  p('----------------------------------------------------------------');
  p(' AGGREGATE DIFF STAT  (' + range + ')');
  p('----------------------------------------------------------------');
  p(aggregate);
  p('');

  p('----------------------------------------------------------------');
  p(' FILES CHANGED  (' + files.length + ')');
  p('----------------------------------------------------------------');
  p('  app file (' + APP + '): ' + (appChanged ? 'CHANGED' : 'unchanged'));
  p('  docs/                          : ' + (docsChanged ? 'CHANGED' : 'unchanged'));
  p('  .github/                       : ' + (ghChanged ? 'CHANGED' : 'unchanged'));
  p('  scripts/                       : ' + (scriptsChanged ? 'CHANGED' : 'unchanged'));
  p('');
  if (files.length === 0) {
    p('  (no files changed in range)');
  } else {
    for (const f of files) p('  ' + f);
  }
  p('');

  p('================================================================');
  p(' ENTRY SKELETON  (File version pre-filled; rest are TODO)');
  p('================================================================');
  p('');
  p('## Trigger');
  p('TODO: what prompted this batch of work.');
  p('');
  p('## Goal');
  p('TODO: what this set of changes was meant to achieve.');
  p('');
  p('## File version');
  p('- Base ref : ' + label + (kind === 'date' ? ' (date)' : ''));
  p('- Base SHA : ' + baseShort);
  p('- HEAD SHA : ' + headSha + ' (' + headFull + ')');
  p('- Range    : ' + range);
  p('- Aggregate: ' + aggregate);
  p('- Commits  : ' + commits.length);
  p('');
  p('## Changes');
  p('TODO: narrative summary of what changed and why. Per-commit raw material:');
  for (const c of commits.slice().reverse()) {
    p('  - ' + c.sha + ' (+' + c.ins + '/-' + c.del + '): ' + c.subject);
  }
  if (commits.length === 0) p('  (no commits in range)');
  p('');
  p('## Test results');
  p('TODO: node --check result, smoke suite result, manual iPad verification.');
  p('');
  p('## Deferred');
  p('TODO: anything spotted but intentionally not shipped in this batch.');
  p('');

  if (tagCount === 0) {
    p('----------------------------------------------------------------');
    p('suggestion: this repo has no git tags, so ranges depend on you');
    p('remembering the last logged SHA/date. Adopting lightweight tags per');
    p('shipped version (e.g. `git tag v4.32` at release) would let you run');
    p('`npm run log:scaffold` with no argument. Suggestion only - not done here.');
    p('');
  }

  return out.join('\n') + '\n';
}

function main() {
  // Confirm we are inside a git work tree before doing anything.
  if (gitQuiet(['rev-parse', '--is-inside-work-tree']) !== 'true') {
    die('error: not inside a git repository.');
  }

  let ref = process.argv[2];

  if (!ref) {
    const latestTag = gitQuiet(['describe', '--tags', '--abbrev=0']);
    if (latestTag) {
      ref = latestTag;
      process.stderr.write('note: no ref given; defaulting to most recent tag "' + ref + '".\n');
    } else {
      die(
        'error: no <last-version-ref> given and this repo has no git tags.\n' +
        'Pass a SHA or date instead, e.g.:\n' +
        '  npm run log:scaffold -- ba8e24b\n' +
        '  npm run log:scaffold -- 2026-06-01\n' +
        '  npm run log:scaffold -- "2 weeks ago"\n' +
        '\nThis app is not git-tagged per version yet. Adopting lightweight\n' +
        'tags per shipped version (git tag v4.32) would let you run this with\n' +
        'no argument and make ranges unambiguous - flagged as a suggestion only.'
      );
    }
  }

  process.stdout.write(generateScaffold(ref));
}

// Run as a CLI only when invoked directly; stay quiet when require()d.
if (require.main === module) {
  main();
}

module.exports = {
  generateScaffold,
  generateScaffoldFromBase,
  resolveBase,
  EMPTY_TREE,
};
