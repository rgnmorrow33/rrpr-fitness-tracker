/* Serves a localStorage-mode copy of the tracker for write-safe local tests.
 *
 * Reads RoundRock_Fitness_Tracker.html, flips STORAGE_MODE from 'supabase'
 * to 'localStorage' in memory (never on disk), and serves the result. Tests
 * against this server exercise the exact repo code with zero network writes -
 * every save lands in the browser context's localStorage and dies with it.
 *
 * Used by playwright.local.config.ts (webServer). Not part of the read-only
 * production smoke suite.
 */
const fs = require('fs');
const http = require('http');
const path = require('path');

const src = path.join(__dirname, '..', 'RoundRock_Fitness_Tracker.html');
let html = fs.readFileSync(src, 'utf8');

const needle = "var STORAGE_MODE = 'supabase';";
const count = html.split(needle).length - 1;
if (count !== 1) {
  console.error(
    'serve-local: expected exactly 1 STORAGE_MODE assignment, found ' + count +
    '. The constant moved or changed shape - update the needle in scripts/serve-local.js.'
  );
  process.exit(1);
}
html = html.replace(needle, "var STORAGE_MODE = 'localStorage';");

const port = Number(process.env.LOCAL_PORT || 4173);
http
  .createServer(function (req, res) {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(html);
  })
  .listen(port, function () {
    console.log('local tracker (localStorage mode) on http://localhost:' + port);
  });
