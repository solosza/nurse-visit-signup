# Nurse Visit Sign-Up

A shared, live sign-up sheet for nurse home visits. Nurses open one link, tap a day, and claim individual visits. Sign-ups save instantly and update for everyone in real time.

## How it works
- **Front-end:** this single `index.html`, hosted free on GitHub Pages.
- **Storage / live sync:** a Supabase (Postgres) database. Each visit is one row; claiming a visit is a single-row update guarded so two nurses can never grab the same visit (the second attempt affects 0 rows and gets "just taken").
- **Live updates:** Supabase Realtime pushes every change to all open pages.

## Config
Set in `index.html` (both are safe to be public — the publishable key only works within the database's row-level-security rules):
- `SUPABASE_URL`
- `SUPABASE_KEY` (publishable / anon key)

## Data
The visit schedule (days, times, patients, tasks) lives in the `visits` table in Supabase, seeded for August 2026 (31 days × 11 visits). Editing the schedule = editing that table.

## Notes / next steps
- No login yet — anyone with the link can view and sign up. Add auth or a passcode before using with real patient data.
- Anyone can currently remove anyone else's sign-up.
- To change the month or schedule, update the `visits` table (or re-seed via the SQL in the project notes).

Planned work, the constraints behind it, and the known defects: **[ROADMAP.md](ROADMAP.md)**.
