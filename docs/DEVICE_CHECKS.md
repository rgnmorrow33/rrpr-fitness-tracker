# Open device checks - Round Rock Fitness Tracker

Running list of things that can only be settled on a real iPad against the live
site. Code review cannot close any of these.

**Canonical location: this file.** If you are reading a Word or PDF copy, it is a
point-in-time snapshot and may be stale. Check here.

- Site: https://pardfitnesstracker2.netlify.app
- Owner of this list: Reagan
- Runs the checks: Selisa
- Last updated: 2026-07-31 (v4.57). **11 checks, all OPEN.** Checks 1 to 6 have
  been open since v4.46 to v4.55. Checks 7 to 11 are new with v4.57 and cover
  deleting things. Run them as one sweep rather than in two visits.
- **Checks 7 to 11 need v4.57 to be live first.** As of 2026-07-31 production is
  still on v4.56. Reagan will confirm when it merges.

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

## Check 6 - Build indicator / manual refresh (v4.55, UNVERIFIED)

**Status: OPEN. This is the one that actually needs your iPad, not a desktop
browser - it exists because of a stale home screen tile you reported on
July 30.**

The login screen now has small text at the bottom reading something like
`v4.55 · tap to refresh`. Two things it's for:

1. **Which build is this.** The version number there should match whatever
   Reagan tells you just shipped. If it doesn't, the device hasn't picked up
   the latest push yet.
2. **Manual refresh.** Tapping that text forces a fresh fetch of the app,
   which is the only way to get a home screen tile unstuck - there's no
   address bar or pull-to-refresh on a tile, so a stale tile had no way to
   fix itself before this.

### The check

1. On an iPad or iPhone with the app installed as a **home screen tile**
   (not just open in Safari), open it and confirm the version text is
   readable at the bottom of the login screen.
2. Tap it.

**PASS:** The app reloads and the version text still reads the current
version afterward.

**If it doesn't fix a stuck/stale tile:** that's the scenario this shipped
for, so it's important - tell Reagan exactly what you saw (did it reload at
all? did the version text change?).

---

## v4.57 checks - deleting things (Checks 7 to 11)

**Do not start these until Reagan confirms v4.57 is merged and live.** The login
screen version text (Check 6) is how you tell: it has to read **v4.57**. If it
still reads v4.56, stop, these five will not mean anything yet.

What changed, in one paragraph: deleting things in the app was inconsistent.
Some Delete buttons worked, some quietly did nothing and the record came back
later, and a few were available to people who should not have had them. All of
that was reworked. These checks confirm the reworked version behaves on a real
device.

---

## Check 7 - A trainer cannot delete attendance (v4.57)

**Status: OPEN. This is the most important one in this batch.**

Before v4.57, any trainer could open any class, including ones they do not
teach, and delete attendance records off it. Nothing stopped them and nothing
recorded it properly.

1. Sign in as a **trainer**, not as Carlos and not as Reagan. Victor Leak works.
2. Go to the schedule and open a class **that trainer does not teach**.
3. Scroll to **Session History**.

**PASS:** There is no delete control next to the attendance rows.

**FAIL:** There is a delete control, and tapping it removes the row.

### If it fails

Send Reagan this exact sentence, with the trainer name and class name:

> "Check 7 FAILED - <trainer> could still delete attendance on <class>."

This is a roll-back-worthy failure. It is the specific hole v4.57 was built to
close.

---

## Check 8 - Undo actually puts it back (v4.57)

**Status: OPEN**

Attendance and session deletes no longer ask "are you sure." Instead they delete
right away and give you eight seconds to tap **Undo**. That is intentional: it is
fewer taps normally and it is recoverable when someone fat-fingers it.

1. Sign in as **Carlos or Reagan**.
2. Open a class with at least two attendance records.
3. Delete one. A small message should appear at the bottom with an **Undo**
   button on it.
4. **Tap Undo before it disappears.**

**PASS:** The row comes back, in the same place in the list it was before.

**FAIL:** Nothing comes back, or it comes back in the wrong place, or there is no
Undo button at all.

Then do the other half:

5. Delete a different attendance record and **do not** tap Undo. Let the message
   disappear on its own.
6. Reload the app.

**PASS:** It is still gone.

**FAIL:** It came back. That means the delete never reached the database, which
is the exact bug this version was fixing.

---

## Check 9 - Deleting a WRO actually deletes it (v4.57)

**Status: OPEN**

Four Delete buttons in the app used to remove the record from the screen without
removing it from the database. It looked like it worked and the record came back
the next time the app loaded.

1. Sign in as an **admin** (Reagan or Tyra).
2. Open a **throwaway** WRO record. Do not use a real member's.
3. Tap **Delete**.

**PASS:** It asks you to type the person's name before it will delete.

4. Type it and confirm.
5. **Reload the app fully.**

**PASS:** It is still gone.

**FAIL:** It reappears after the reload.

---

## Check 10 - Lead no longer sees WRO and referral Delete (v4.57)

**Status: OPEN**

Carlos could see these buttons before, but they never actually worked for him,
so what he got was a delete that looked successful and undid itself. The buttons
are now hidden rather than lying.

1. Sign in as **Carlos** (lead).
2. Open a WRO record. Then open a referral record.

**PASS:** There is no Delete button on either.

**FAIL:** The button is still there. Note which one and tell Reagan.

This one is worth mentioning to Carlos directly so it does not look like
something broke.

---

## Check 11 - Removing a team member with clients is refused (v4.57)

**Status: OPEN**

1. Sign in as an **admin**.
2. Go to the team member list and try to remove someone who currently has
   clients or classes assigned. **Marcellus is a good example. Do not actually
   remove anyone real.**

**PASS:** It refuses outright and tells you why. It should not offer you a way
to proceed anyway.

**FAIL:** It warns you but lets you continue. Before v4.57 it did exactly that,
which is how you end up with clients pointing at a team member who no longer
exists.

Cancel out either way. Do not remove a real team member for this check.
---

## Completed

Nothing yet. This list was created 2026-07-14.
