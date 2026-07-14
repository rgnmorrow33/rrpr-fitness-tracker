# Open device checks - Round Rock Fitness Tracker

Running list of things that can only be settled on a real iPad against the live
site. Code review cannot close any of these.

**Canonical location: this file.** If you are reading a Word or PDF copy, it is a
point-in-time snapshot and may be stale. Check here.

- Site: https://pardfitnesstracker2.netlify.app
- Owner of this list: Reagan
- Runs the checks: Selisa
- Last updated: 2026-07-14 (v4.48)

## How to use this

Each check says what to do, what PASS looks like, and what to do if it fails.
You do not need to know why the code does what it does. If a check fails, stop,
write down exactly what you saw, and send it to Reagan. Do not try to work
around a failure.

Mark each one DONE with the date and your initials when it passes.

---

## P1 - Live sync between two iPads

**Status: OPEN. This is the important one.**

Background you actually need: on July 14 the app's security was tightened so that
nobody can read member data without signing in. That was the right change. What
nobody has confirmed is whether **live updates between iPads still work** after
it. Everything else about the app looks completely normal either way, which is
exactly why this needs a human with two iPads.

### The check

1. Open the site on **two iPads**. Sign in on both. Leave both sitting on the
   schedule.
2. On **iPad A**, drop a class for sub coverage.
3. Watch **iPad B**. Do not touch it. Do not reload it. Do not lock it.

### PASS

The dropped class appears on iPad B **on its own, within a few seconds**, with no
reload and no tapping.

### FAIL

The class does NOT appear on iPad B until you reload it, navigate away and back,
or lock and unlock the screen.

### If it fails

This is a real bug, not a fluke. It means two trainers on two iPads have not been
seeing each other's changes in real time since the morning of July 14, and nothing
in the app would have told them. Send Reagan this exact sentence:

> "Two-iPad check FAILED - the class only showed on the second iPad after a reload."

There is no danger to the data. Nothing is lost. It just means changes are not
pushing live, and Reagan has a known fix ready.

---

## Check 2 - Signed-out console is quiet (v4.47)

**Status: OPEN**

1. Load the site on an iPad and **do not sign in**. Sit on the login screen.
2. Reload the page three or four times, still signed out.

**PASS:** Nothing looks wrong. The trainer name list appears normally each time.

If you can get to a browser console (Safari on a Mac connected to the iPad, or
just do this step on a desktop browser instead), it should be **quiet**. Before
July 14 it filled with red `permission denied for table` errors on every load.

**If you see those errors:** send Reagan a screenshot. Not urgent, not dangerous.

---

## Check 3 - Realtime channels come up (v4.48)

**Status: OPEN. Desktop browser is fine for this one, no iPad needed.**

1. Open the site in a desktop browser, open the developer console, sign in.
2. Look for lines that read `[realtime] live table-changes-...`

**PASS:** You see **four** of them: `clients`, `classes`, `leads`,
`trainer_time_off`.

**If you see fewer than four:** note which ones are missing and send it to Reagan.
This is closely related to P1 above.

---

## Check 4 - Security lockdown still holds (v4.46)

**Status: OPEN. Worth re-running because it is the highest-stakes one.**

1. Open the site in a desktop browser, **signed out**.
2. Open the developer console and run:

       await supabaseClient.from('clients').select('*')

**PASS:** It comes back with a **permission error**.

**FAIL:** It returns actual client records.

### If it fails

**Stop and call Reagan immediately.** Do not wait, do not email. A fail here means
member data including health questionnaires is readable by anyone on the internet,
and the app needs to be rolled back.

This passed when it was tested on July 14. Re-running it costs thirty seconds and
it is the one thing worth being paranoid about.

---

## Check 5 - Overnight session expiry (v4.46)

**Status: OPEN**

Leave an iPad signed in overnight.

**PASS:** The next morning it asks for the PIN again.

**FAIL:** It still looks signed in, but logging a session silently does nothing.

If it looks signed in the next morning, log one test session, reload, and see
whether it survived. If it vanished, tell Reagan.

---

## Completed

Nothing yet. This list was created 2026-07-14.
