/* Serves staging/local-branch.html (the key-bearing local staging copy) over
 * http, so the app runs against a real Supabase branch in a real browser.
 *
 * Re-reads the file on EVERY request. The first version cached it at startup,
 * which meant editing the HTML and hard-refreshing the browser changed nothing -
 * the server kept handing out the stale copy and we chased a ghost bug. Reading
 * a 1.4 MB file per request is irrelevant for a single local tester.
 *
 * The file it serves is gitignored (staging/local-*.html) because it carries
 * live branch keys. The tracked staging/*.staging.html keeps placeholders.
 *
 * Usage:  npm run serve:staging   ->  http://localhost:4174
 */
const fs = require('fs');
const http = require('http');
const path = require('path');

const src = path.join(__dirname, '..', 'staging', 'local-branch.html');
const port = Number(process.env.STAGING_PORT || 4174);

http.createServer(function (req, res) {
  let html;
  try {
    html = fs.readFileSync(src, 'utf8');   // fresh read, every request
  } catch (e) {
    res.writeHead(500, { 'Content-Type': 'text/plain' });
    res.end('serve-staging: staging/local-branch.html not found.\n');
    return;
  }
  if (html.indexOf('YOUR-STAGING-PROJECT-REF') !== -1 || html.indexOf('PASTE-STAGING-ANON-KEY') !== -1) {
    res.writeHead(500, { 'Content-Type': 'text/plain' });
    res.end('serve-staging: local-branch.html still has placeholder credentials.\n');
    return;
  }
  // Which project is this actually pointed at? Print it so nobody tests prod by accident.
  const m = html.match(/var SUPABASE_URL = '([^']+)'/);
  console.log(new Date().toISOString(), req.method, req.url, '->', m ? m[1] : 'UNKNOWN');
  res.writeHead(200, {
    'Content-Type': 'text/html; charset=utf-8',
    'Cache-Control': 'no-store, no-cache, must-revalidate',
    'Pragma': 'no-cache'
  });
  res.end(html);
}).listen(port, function () {
  const html = fs.readFileSync(src, 'utf8');
  const m = html.match(/var SUPABASE_URL = '([^']+)'/);
  console.log('Staging tracker on http://localhost:' + port);
  console.log('Supabase project: ' + (m ? m[1] : 'UNKNOWN'));
  if (m && m[1].indexOf('ofezaezijafglyjmisgz') !== -1) {
    console.log('*** WARNING: that is PRODUCTION. Stop. ***');
  }
  console.log('Re-reads the file on every request - just refresh the browser after an edit.');
}).on('error', function (e) {
  if (e.code === 'EADDRINUSE') {
    console.error('Port ' + port + ' already in use - an older serve-staging is still running.');
    console.error('Kill it first, or it will keep serving the OLD file.');
  } else { console.error(e); }
});
