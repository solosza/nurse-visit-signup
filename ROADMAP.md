# Roadmap

The planned work for this app, the constraints that shape it, and the known defects. This
file is the working spec — if a decision here turns out wrong, change it here rather than
letting the code and the plan drift apart.

Last updated: 2026-08-19

---

## Requested features

The list as asked for, unedited. Ordering here is the request order, not the build order.

1. Ongoing months (not a single seeded month)
2. Colour coding per nurse, set when the nurse sets their name
3. Editing visit details and times
4. "Give me my schedule" — a nurse sees the visits they signed up for
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
| Auth | none today — publishable/anon key in page source, guarded only by RLS |

A push to `master` redeploys the live page within about a minute.

---

## Constraints

These are the things that are easy to get wrong here and expensive to get wrong.

### 1. "Production" is the database, not the page

The page is a static client. A git branch protects the HTML and **nothing else** — a
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

Additive changes (`ALTER TABLE … ADD COLUMN`) are non-breaking — the currently deployed
page ignores columns it does not know about. Prefer additive migrations so `master` keeps
working while a branch is in progress.

### 3. Identity is the backbone of half the list

Nurse identity today is a name typed into a `prompt()` and kept in `localStorage`. There
are no accounts. Consequences: two nurses typing "Sarah" are one person, one nurse on two
devices is two people, and anyone can clear storage and become anyone.

Features 2, 4, 8 and the cancel-ownership fix all depend on knowing which nurse is which.
A timesheet that totals hours is payroll-adjacent and cannot rest on a string a user can
retype at will. **Decide identity before building anything that reads it.**

### 4. Patient data is ALREADY publicly readable — this is remediation, not prevention

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

So feature 6 is not a precaution taken before feature 7 — it is a fix for a live condition.

A client-side passcode prompt **does not** address it. The key is in the page source, so
anyone can query Supabase directly and never load the page at all. Gating the HTML gates
nothing. Real protection is Supabase Auth plus RLS policies keyed to an authenticated
session, so that the anon role can read nothing.

Note the tension with a fix: the nurses currently using the live sheet depend on anon
access working. Tightening RLS without shipping auth in the same change locks them out.
That is why step 2 in the build order is auth **and** identity together, not RLS alone.

---

## Known defects

Found while reading the code on 2026-08-19. None are fixed yet.

| # | Defect | Where |
|---|--------|-------|
| D1 | Any nurse can remove any other nurse's sign-up — `release()` has no ownership check, and for someone else's claim the button reads "Remove" with only a `confirm()` in the way. Needs a client guard **and** an RLS policy; the client guard alone is cosmetic. | `index.html`, `release()` |
| D2 | Realtime ignores DELETE events. The handler reads `payload.new`, which is empty on a delete, so a deleted row stays on screen until a manual refresh. | `index.html`, `subscribeLive()` |
| D3 | `MONTH_LABEL` is hardcoded `"August 2026"`. The grid renders whatever dates exist in the table, so the header will lie as soon as the data moves on. Blocks feature 1. | `index.html` |
| D4 | `CAPACITY = 11` is declared and never used. Dead constant — remove it or wire it up. | `index.html` |
| D5 | **Live data exposure.** 341 rows — patient first names, care tasks, nurse names, locations — are readable by any anonymous request carrying the publishable key from the page source. Measured 2026-08-19, not inferred. See constraint 4. This is the highest-severity item on this page and it is live right now. | Supabase RLS on `visits` |

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
