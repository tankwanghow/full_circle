---
name: mix-dependency-overrides
description: Use when `mix hex.outdated` prints "Update not possible", when `mix deps.update <dep>` silently leaves a package on its old version, when adding or removing an `override: true` pin in mix.exs, or when reviewing/refreshing the standing gettext and decimal overrides. Covers finding the blocking package and the evidence bar for overriding a stale requirement.
---

# Mix Dependency Overrides

Two deps in `mix.exs` carry `override: true`: `decimal` and `gettext`. They are not
leftovers and they are not laziness — **delete them and `ecto_sql`, `ecto` and `gettext`
all silently roll back a major version.** This skill is the decision procedure behind
them, because the mix.exs comments only record the conclusion, not how to redo the work.

## The blocker is never the package you're trying to update

`mix hex.outdated` tells you *that* something is stuck. It never tells you *who* is
holding it. For that, ask about the stuck package by name:

```
$ mix hex.outdated decimal

Source       Requirement                 Up-to-date
mix.exs      ~> 3.1                      Yes
ecto         ~> 3.0                      Yes
number       ~> 1.5 or ~> 2.0            No      <-- the blocker
postgrex     ~> 1.5 or ~> 2.0 or ~> 3.0  Yes
```

Every package declaring a requirement is listed, and `Up-to-date: No` marks the stale
one. Do this before forming any opinion — it is one command and it names the problem.

A second symptom of the same thing: `mix deps.update ecto_sql` exits 0 and changes
nothing. Mix is not broken; the resolver picked the newest version that satisfies
everyone, which is the old one. Silence here means "go run `mix hex.outdated` on the
transitive dep", not "this dependency is stuck forever".

## `override: true` resolves. It is not a force flag.

The tempting wrong conclusion is that because `timex` declares `gettext ~> 0.26`,
raising your own pin to `~> 1.0` will fail to resolve. **It resolves fine.**
`override: true` tells Hex that your top-level requirement wins over transitive ones,
and resolution then proceeds normally.

So "it won't resolve" is never the reason to decline. The real question is whether the
blocking package *actually breaks* at the new version — which is an empirical question
with a cheap answer, not something to infer from the version number.

## The evidence bar

A major version bump is not evidence of breakage. Run all four checks; override only if
all four pass.

1. **Is the blocker already at its own latest release?** `mix hex.outdated` again. If a
   newer release of the blocker exists, just update it — no override needed. If it *is*
   current, its requirement is stale rather than protective, and upstream isn't going to
   fix it on your schedule.
2. **Read the new major's CHANGELOG.** Fetch it, don't guess:
   `mix hex.package fetch gettext 1.0.2 --unpack --output /tmp/<scratch>/gettext-1.0.2`
   then read its `CHANGELOG.md`. gettext 1.0.0 says in as many words: *"There are very
   few changes from the latest 0.26 release, and none of them are breaking."* A version
   number that looks alarming and a changelog that says "no breaking changes" is the
   normal case for a 1.0. The inverse trap: for a pre-1.0 package a *minor* bump
   (`0.2 → 0.3`) is allowed to break, so read those changelogs with the same suspicion
   you'd give a major.
3. **Audit what the blocker actually calls.** Not what it might call — what it does:
   `grep -rhoE "Decimal\.[a-z_]+[!?]?" deps/number/lib | sort -u`. `number` touches
   `new/from_float/compare/div/round/abs/to_string/to_integer`, every one unchanged
   across decimal 2.x → 3.x. That is what makes its `~> 2.0` stale rather than meaningful.
4. **Audit your own call sites against the specific breaking changes**, listed one by
   one. decimal 3.x tightened `parse`/`cast` to reject >34 digits — all 15
   `Decimal.parse/1` call sites here already `case` on the result and match the failure
   branch (`:error ->` or a `_ ->` catch-all), so the new return degrades gracefully
   instead of crashing. Check the actual list; don't reason from the headline.

If a check fails, don't override — but say which check failed. "It's a major version"
is not a finding.

## The two standing overrides

| Pin | Blocker | Why the requirement is stale |
|---|---|---|
| `{:gettext, "~> 1.0", override: true}` | `timex 3.7.13` declares `gettext ~> 0.26` | gettext 1.0.0 is 0.26 with no breaking changes; timex already uses the modern `Gettext.Backend` API |
| `{:decimal, "~> 3.1", override: true}` | `number 1.0.5` declares `decimal ~> 1.5 or ~> 2.0` | `number` only calls APIs unchanged in 3.x; its `Number.Decimal.compare/2` shim already handles `:lt/:gt/:eq` |

The decimal pin is load-bearing beyond decimal itself: `ecto_sql 3.14` requires
`decimal ~> 3.0`, so **removing it drags `ecto_sql` back to 3.13 and `ecto` to 3.13.**

Both blockers were at their latest release when this was written, so neither resolves
itself by waiting.

## Deleting an override

Re-run the same diagnostic. When the blocker's row reads `Up-to-date: Yes`, its
requirement now admits the version you pinned, the override is redundant, and you can
drop it:

```
$ mix hex.outdated gettext
Source   Requirement  Up-to-date
mix.exs  ~> 1.0       Yes
timex    ~> 0.26      No        <-- still stale: keep the override
```

Don't delete on the theory that it "looks unnecessary" — `mix deps.get` will happily
resolve to the older version and nothing will fail loudly.

## Verification bar for a dependency change here

Money and dates run through these libraries, so compile-clean is not sufficient:

```bash
mix compile --force       # app must be warning-free; timex's own struct-update warnings are pre-existing
mix test                  # full suite, currently 1797 tests
timeout 35 mix phx.server # boots on :4000/:4001
```

For a decimal or gettext change specifically, also smoke-test the paths no test covers —
`Number.Currency.number_to_currency/2` output, `Decimal.div` precision, and
`Timex.lformat!(d, fmt, "zh_CN")` for translation lookup — with
`mix run --no-start -e '...'`.

Note `Decimal.div`'s default context precision moved 28 → 34 digits in decimal 3.x. That
only adds digits upstream of the `Decimal.round(2)` / `money()` calls, but it does mean
an unrounded `div` result renders differently than it used to.

## Common mistakes

- **Inferring breakage from the version number.** Read the changelog. 1.0 releases are
  frequently the previous minor with a stable-API promise.
- **Treating a transitive requirement as a safety assertion.** It records what the author
  tested against on release day, not what breaks.
- **Reaching for a fork or a rewrite first.** Replacing `number` means touching 279 call
  sites; an override backed by the four checks above costs an afternoon.
- **Overriding without recording why.** Every override needs a mix.exs comment naming the
  blocker and the stale requirement, or the next session deletes it.
