---
name: deploy-image-size
description: Use when the Docker image or Linode deploy upload is too big, when auditing what ships to production, when adding files under priv/ or priv/static, or when removing a feature that had JS assets, model weights, wasm or fixture data. Covers why priv/static costs double, why static_paths and priv/static drift apart silently, and how to measure the real deploy cost.
---

# Deploy Image Size

Deploy cost is dominated by **data files under `priv/`**, not by code. At the 2026-09-16
audit the release was 181 MB, of which compiled BEAM code was **9.8 MB** — 5%. Refactoring
Elixir to shrink the image is wasted effort; find the data instead.

## 1. Everything under `priv/static` ships **twice**

`mix assets.deploy` runs `phx.digest`, which fingerprints **every file** under
`priv/static` — not just the esbuild/tailwind output. Each file ships as the original
*and* a hashed copy:

```
13.31 MB  priv/static/human-models/faceres-deep.bin
13.31 MB  priv/static/human-models/faceres-deep-b96d1ac5834a293f7c4bc1ac091044f1.bin
```

**A 47 MB directory dropped in `priv/static` costs 94 MB in the image.** This applies to
files that are never served and never referenced — digest does not consult `static_paths`.

Corollary: `priv/static` is for things the browser fetches. Anything else (fixtures,
ops data, reference blobs) belongs outside it, or outside `priv/` entirely.

## 2. `static_paths` and `priv/static` drift apart silently, in both directions

`FullCircleWeb.static_paths/0` (`lib/full_circle_web.ex`) feeds `Plug.Static`'s `only:`
option. It controls **what is served**, never **what is shipped**. Both failure modes are
silent:

| Drift | Effect | How it looks |
|---|---|---|
| Dir in `priv/static`, not in `static_paths` | Ships, 2x, permanently 404s | `priv/static/reader/zxing_reader.wasm` — 1.9 MB nobody could ever fetch |
| Name in `static_paths`, no such dir | Nothing; silently ignored | `fonts`, `sounds`, `face-api-models` sat there long after deletion |

Neither raises, warns, or fails a test. **Grep both directions after touching either.**

## 3. Deleting a feature does not delete its assets

`51ed48ab feat: remove Face ID and Take Photo` deleted `assets/js/face_id.js`,
`take_photo_human.js` and all of `assets/vendor/human-main/` — and left 47 MB of
TensorFlow weights in `priv/static/human-models/`, which then shipped (at 94 MB) for
months. The only surviving reference was the stale `static_paths` entry.

**When removing a feature with a JS/asset side, check `priv/static` for its runtime data
in the same commit.** Model weights, wasm, fonts and sample files have no compiler or test
to notice they are orphaned.

## 4. `priv/` ships wholesale — including untracked ops data

The Dockerfile does `COPY full_circle/priv priv` and `mix release` bundles the app's whole
`priv/`. So:

- **Untracked still ships.** `priv/xero_import/golden_husbandry` was 24 MB of untracked
  local JSON that went to production every deploy. `.gitignore` does not help here;
  `.dockerignore` does.
- **Mix-task-only data is always dead weight.** Mix is not in a release, so
  `mix full_circle.import_xero` can never run in prod. Anything under `priv/` that only a
  Mix task or a `scripts/*.py` reads should be `.dockerignore`d.

Before adding a `priv/` subdir, ask: does the *running server* read this? If not, exclude it.

## 5. Build context is the monorepo root, and the sibling list is manual

`deploy_to_linode/deploy.sh` builds with `$MONOREPO_ROOT` as context and copies
`full_circle/.dockerignore` to the root. That `.dockerignore` excludes sibling apps
**by name** (`argus/`, `peggy/`, `pou_con/`, `tugas/`, …).

**A new app added to the monorepo silently joins the build context.** `tugas/` (201 MB)
did exactly this. It never reaches the image — nothing `COPY`s it — so image size looks
fine while every build ships it to the daemon. Re-check this list when the monorepo grows.

## 6. Measure the transfer, not the image

Deploy is `docker save | gzip | ssh` (`deploy.sh`), so the number that matters is the
**gzipped save**, and it does not track image size. Already-compressed payloads (NN
weights, wasm, JPEG, PDF) shrink ~0% and so dominate the upload far more than their share
of the image suggests — the face models gzipped at **93%**, i.e. ~83 MB of a 162 MB upload.

### Audit procedure

```bash
# 1. What is actually in the shipped image (works on any built tag)
cid=$(docker create <image>)
docker export $cid | tar -tvf - | awk '{print $3"\t"$6}' > /tmp/imgfiles.txt
docker rm $cid

# 2. Attribute the release payload
awk -F'\t' '$2 ~ /^app\/lib\/full_circle-[^\/]+\//{
  split($2,p,"/"); k=p[4]"/"p[5]"/"p[6]; s[k]+=$1
} END {for (k in s) printf "%8.2f MB  %s\n", s[k]/1048576, k}' /tmp/imgfiles.txt | sort -rn | head -20

# 3. The number that actually costs you
docker save <image> | gzip -c | wc -c
```

Step 2 is the money shot: it ranks `priv/` subdirectories against `ebin/`, which is how
the "code is only 5%" conclusion falls out immediately.

## 7. Known remaining slack (not yet done)

Measured, deliberately deferred — pick these up if the image matters again:

| Item | Saves | Note |
|---|---|---|
| `countries` + `yamerl` deps → static list | ~8 MB | Used only by `Sys.countries/0`; the bulk is per-country subdivision YAML never touched |
| `rm -rf /usr/share/i18n` after `locale-gen` | ~15 MB | Locale *source*; compiled output in `/usr/lib/locale` is what runs |
| `apt-get --no-install-recommends` in runner | ~16 MB | Drops `poppler-data` (13 MB) + `fonts-dejavu-core`. **Caveat:** `poppler-data` is CJK CMaps for `pdftotext`; test against a real bank statement first (see `bank-recon-llm-parser`) |
| `tz` instead of `tzdata` | ~3 MB | `tzdata` hard-depends on hackney purely to auto-update, which `config.exs` already sets `:disabled`. Would touch the 3 `Tzdata.zone_list()` call sites |

Also unresolved: `Plug.Static` has `gzip: false` while `phx.digest` generates 38 `.gz`
files. They are built, shipped, and never served — and assets go out uncompressed.

## Baseline (commit f0dad255, 2026-09-16)

Re-measure against these; a jump means something new landed in `priv/`.

| | Value |
|---|---|
| Release layer | 72.7 MB |
| Image total | 326 MB |
| `docker save \| gzip` | **75 MB** |
| App BEAM code (`ebin/`) | 9.8 MB |
