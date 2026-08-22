# Roadmap

The planned work for this app, the constraints that shape it, and the known defects. This
file is the working spec, if a decision here turns out wrong, change it here rather than
letting the code and the plan drift apart.

Last updated: 2026-08-19

---

## Requested features

The list as asked for, unedited. Ordering here is the request order, not the build order.

1. Ongoing months (not a single seeded month)
2. Colour coding per nurse, set when the nurse sets their name
3. Editing visit details and times
4. "Give me my schedule", a nurse sees the visits they signed up for
5. An easy-to-read month calendar of visits, separated by facility, based on sign-ups
6. A passcode to protect the link
7. Facility address and patient info on each visit
8. A timesheet log totalling hours of visits
9. Add visits to Google Calendar

---

## How this is deployed

| Thing | Where |
|-------|-------|
| Page | `index.html`, single file, no build step |
| Hosting | GitHub Pages, **`master` branch, root path**, legacy build, no Actions |
| Live URL | https://solosza.github.io/nurse-visit-signup/ |
| Data + realtime | Supabase (Postgres), `visits` table |
| Auth | none today, publishable/anon key in page source, guarded only by RLS |

A push to `master` redeploys the live page within about a minute.

---

## Constraints

These are the things that are easy to get wrong here and expensive to get wrong.

### 1. "Production" is the database, not the page

The page is a static client. A git branch protects the HTML and **nothing else**, a
branch copy opened locally still points at the same Supabase project and still writes to
real nurse sign-ups.

So staging means **separate data**, not a separate branch:

- **Code** → a git branch, as normal.
- **Data** → a parallel table set (`visits_dev`) in the same Supabase project. `index.html`
  gets a table-name constant selected by a `?dev=1` flag or by hostname.
- **Testing** → open the branch's `index.html` locally (or `python -m http.server`) against
  `visits_dev`. That is production-equivalent: Pages only serves static files over HTTPS,
  so it adds nothing that needs testing.
- **Shipping** → run the migration SQL against the real tables, merge the branch to
  `master`, Pages redeploys.

GitHub Pages serves exactly one branch on the legacy build, so a second branch cannot give
a second preview URL. If a shareable staging link is wanted (to let a nurse trial a change
before it goes live), the cheap route is a second repo, `nurse-visit-signup-staging`, with
Pages enabled.

### 2. Schema changes need a human

The key in the page is the publishable/anon key. It is RLS-limited and **cannot create or
alter tables**. Every schema change is written as SQL and pasted into the Supabase SQL
editor by hand. Plan migrations as deliverables, not as incidental steps.

Additive changes (`ALTER TABLE … ADD COLUMN`) are non-breaking, the currently deployed
page ignores columns it does not know about. Prefer additive migrations so `master` keeps
working while a branch is in progress.

### 3. Identity is the backbone of half the list

Nurse identity today is a name typed into a `prompt()` and kept in `localStorage`. There
are no accounts. Consequences: two nurses typing "Sarah" are one person, one nurse on two
devices is two people, and anyone can clear storage and become anyone.

Features 2, 4, 8 and the cancel-ownership fix all depend on knowing which nurse is which.
A timesheet that totals hours is payroll-adjacent and cannot rest on a string a user can
retype at will. **Decide identity before building anything that reads it.**

### 4. Patient data is ALREADY publicly readable: this is remediation, not prevention

**Corrected 2026-08-19.** This section previously said adding patient details *would* put
PHI behind a public URL. That was wrong in tense. It is already there.

Measured, not inferred: an anonymous request using only the publishable key that is in the
page source returns **341 rows**, containing **4 distinct patient first names**, **6 care
task descriptions** (e.g. "All vitals & breathing treatment"), **10 nurse names**, and **3
locations**. No login, no passcode, no dashboard access. Anyone who opens View Source on
the live site has everything needed to do the same:

```
curl -H "apikey: <the key in index.html>" \
  "https://<project>.supabase.co/rest/v1/visits?select=*"
```

So feature 6 is not a precaution taken before feature 7, it is a fix for a live condition.

A client-side passcode prompt **does not** address it. The key is in the page source, so
anyone can query Supabase directly and never load the page at all. Gating the HTML gates
nothing. Real protection is Supabase Auth plus RLS policies keyed to an authenticated
session, so that the anon role can read nothing.

Note the tension with a fix: the nurses currently using the live sheet depend on anon
access working. Tightening RLS without shipping auth in the same change locks them out.
That is why step 2 in the build order is auth **and** identity together, not RLS alone.

---

## Current state (2026-08-22)

| Item | Status |
|------|--------|
| Dev/prod data split (`visits_dev`) | **done**, live |
| Month label derived from data (D3) | **done**, live |
| Dead `CAPACITY` constant (D4) | **done**, live |
| Anonymous WRITE scoped to claim columns | **done**, live on both tables |
| Latent TRUNCATE/REFERENCES/TRIGGER grants | **done**, revoked on both tables |
| Passcode gate in the page | **shipped but dormant**, appears only once `003b` runs |
| Feature 1: ongoing months | **done**, live |
| Feature 2: colour coding per nurse | **done**, live |
| Feature 4: "my visits" | **done**, live |
| Feature 5: facility month calendar | **done**, live |
| Anonymous READ of patient data (D5) | **still open**, one command away, see below |
| Cancel-ownership (D1) | still open, needs per-nurse identity |
| Realtime DELETE handling (D2) | still open |
| Features 3, 7, 8, 9 | not started |

**6 of 9 requested features are built. 5 are live** (feature 6, the passcode, is
shipped but dormant until `003b` runs).

### Correction: features 2 and 5 were one feature, not two

Raina replied to the test on 2026-08-21 asking for the by-facility view to be a
calendar, and attached a photo of the paper version she uses. The photo settled a
question this document had got wrong.

It shows a month grid with every nurse's name colour-highlighted. **The colour
coding is what makes the calendar readable**, a month of plain names is a wall of
text; the colours are how you see at a glance that one nurse has every evening
this week. They are the same feature.

This document previously listed colour coding as blocked on per-nurse accounts.
**That was wrong.** Colour is a display concern keyed to whatever name is on the
sign-up. It needs no accounts, and it now works: colours are assigned by position
in the roster of nurses present in the data, so a new nurse gets a distinct colour
with no configuration and no table row.

Feature 8 (timesheet) **is** still genuinely blocked on identity. A payroll-adjacent
total of hours cannot rest on a name anyone can retype. Features 3 and 7 need
schema changes. Feature 9 needs the `.ics`-versus-Google-API decision.

### What the calendar does differently from the paper version

Two deliberate departures, both forced by the real data rather than by preference:

- **Unclaimed visits show as "open."** The paper calendar only lists filled shifts.
  This is a sign-up sheet, so finding the gaps is the entire point. They are dimmed
  so they do not drown out the names.
- **Day cells hold a variable number of visits.** The photo shows a fixed 7am/6pm
  pair. The real schedule has 11 distinct times across three sections and 1 to 4
  visits per facility per day.

Structure, for the next round of changes: nurse colours come from roster position
(adding a nurse needs nothing), facilities come from the `location` column (adding
one needs no code), and views are a registry (adding one is a single entry).

### The one command left, and why it is not run yet

`db/003-require-auth.sql` section **003b** is commented out. Running it restricts
`visits` to authenticated readers and closes D5 completely.

**It locks out every nurse who does not yet have the passcode.** That is a real
disruption to a live scheduling tool, and distributing the passcode is a human
step. So: tell the nurses the passcode, then uncomment 003b and run it. The page
already handles both states, no redeploy is needed at cutover.

The shared account is `nurses@nursevisitsignup.app`; its password is the passcode,
and it can be changed any time in Supabase → Authentication → Users.

---

## Known defects

Found while reading the code on 2026-08-19.

| # | Defect | Where |
|---|--------|-------|
| D1 | Any nurse can remove any other nurse's sign-up, `release()` has no ownership check, and for someone else's claim the button reads "Remove" with only a `confirm()` in the way. Needs a client guard **and** an RLS policy; the client guard alone is cosmetic. | `index.html`, `release()` |
| D2 | Realtime ignores DELETE events. The handler reads `payload.new`, which is empty on a delete, so a deleted row stays on screen until a manual refresh. | `index.html`, `subscribeLive()` |
| D3 | ~~FIXED 2026-08-19~~ `MONTH_LABEL` was hardcoded `"August 2026"`. The grid renders whatever dates exist in the table, so the header will lie as soon as the data moves on. Blocks feature 1. | `index.html` |
| D4 | ~~FIXED 2026-08-19~~ `CAPACITY = 11` was declared and never used. Dead constant, remove it or wire it up. | `index.html` |
| D5 | **WRITE half fixed 2026-08-19; READ half still open.** Live data exposure. 341 rows, patient first names, care tasks, nurse names, locations, are readable by any anonymous request carrying the publishable key from the page source. Measured 2026-08-19, not inferred. See constraint 4. This is the highest-severity item on this page and it is live right now. | Supabase RLS on `visits` |

---

## Build order

Chosen so that each step unblocks the next, and so nothing user-visible ships before it is
safe to.

| Step | Work | Why here |
|------|------|----------|
| 1 | Dev/prod table split, working branch, `MONTH_LABEL` derived from the data (fixes D3) | Creates the safe workspace everything else needs. Ships nothing user-visible. |
| 2 | Nurse identity + passcode/auth + RLS (feature 6) | Unblocks features 2, 4, 8 and the D1 fix, and gates the PHI work. |
| 3 | Cancel-ownership fix (D1) | Needs real identity from step 2 to be enforceable rather than cosmetic. |
| 4 | Ongoing months (feature 1) | Rolling schedule replacing the one-month seed. |
| 5 | Editing visit details and times (feature 3) | |
| 6 | "My schedule" (feature 4) and facility-grouped calendar (feature 5) | Both are views over data that steps 2 and 4 make trustworthy. |
| 7 | Facility address and patient info (feature 7) | Deliberately after step 2. See constraint 4. |
| 8 | Timesheet totals (feature 8) | Needs identity (step 2) and edited/accurate times (step 5). |
| 9 | Calendar export (feature 9) | Last. An `.ics` download is small and works with every calendar app; the Google Calendar API needs OAuth and is substantially more work. Pick one before starting. |

Colour coding per nurse (feature 2) rides along with step 2, since it is set at the moment
a nurse's identity is established.

---

## Open questions

- **Identity model:** lightweight nurse records in Postgres, or full Supabase Auth
  (email/magic link)? Auth is more work but is the only version that makes RLS meaningful
  and the timesheet trustworthy.
- **Passcode vs. accounts:** a single shared passcode is much simpler, but it cannot
  attribute a sign-up to a person, which features 2, 4 and 8 all require.
- **Calendar export:** `.ics` file or Google Calendar API?
- **Facility model:** is `location` on a visit enough, or does a `facilities` table
  (with address) need to exist for feature 5 and 7 to group properly?
- **Retention:** do past months stay queryable for the timesheet, and for how long?
