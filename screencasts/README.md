# Screencasts

Generates the tutorial videos in `docs/screencasts/` by driving the real app with
Playwright. Design: `docs/superpowers/specs/2026-08-04-tutorial-screencasts-design.md`.

## Setup (once)

```bash
cd screencasts
npm install
npx playwright install chromium
```

## Recording

The dev server must be running (`mix phx.server`) and these must be exported:

```bash
export SCREENCAST_EMAIL=you@example.com
export SCREENCAST_PASSWORD=...
```

```bash
node record.mjs --doctor    # check deps, creds and server before anything else
node record.mjs 01          # record one lesson to docs/screencasts/
node record.mjs --all       # record everything
node record.mjs 01 --dry    # run the script without recording (fast selector check)
node build-index.mjs        # regenerate docs/screencasts/index.html
```

If a lesson cannot find a customer or a good, point it at data that exists in
your dev database:

```bash
export SCREENCAST_CUSTOMER="Ah Seng"
export SCREENCAST_GOOD_1="Egg"
```

## After changing UI

Run `node record.mjs --all --dry` after touching Billing LiveViews. It runs every
lesson script with no recording and fails loudly on any selector that no longer
resolves, so you learn immediately which lessons need re-recording.

## Adding a lesson

1. Add `lessons/NN-<slug>.mjs` exporting `id`, `title`, `description`, `run(d)`.
2. Add the matching entry to `manifest.json`.
3. `node record.mjs NN --dry`, then `node record.mjs NN`, then `node build-index.mjs`.

## Rules

- **Never commit mp4 files.** They are gitignored and reproducible from these scripts.
- **Recordings show production-derived data.** The dev database is restored from
  prod backups, so videos contain real customer and payroll names. Internal
  distribution only — never upload them anywhere public.
- Lessons that save a document consume a real gapless document number and append
  it to `.created.log` so you can clean up later.
- Autocomplete fields use Tribute in `autocompleteMode`, which only reacts to real
  key events. Always use `d.pickAutocomplete()`, never `fill()`.
- **Do not type spaces into Tribute fields.** Space is a menu action; the fuzzy
  filter matches char-by-char, so `pickAutocomplete` strips spaces when typing
  (`"Agri Channel"` → keys `AgriChannel`) and then clicks the matching list item.
