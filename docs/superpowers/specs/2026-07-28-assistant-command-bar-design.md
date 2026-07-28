# Assistant Command Bar

**Date:** 2026-07-28
**Status:** Design approved, not implemented
**Supersedes nothing.** Phase 1 ships one handler (egg stock planned orders); the
architecture is app-wide from day one.

## Problem

Entering a planned egg order today means: navigate to the day board for the right
date, add a detail line, pick the contact from an autocomplete, then tab across a
grade column per quantity. A clerk taking orders by phone does this dozens of
times a day, and the phone call already contained everything needed:

> Swee Heng order Egg A 100, B 300, D 800 30/07/2026

The goal is a command bar that turns that sentence into the planned order line,
and refuses honestly when it cannot.

The bar is **app-wide by design and phased by capability**. Adding a command must
mean adding one module, not touching a router. Anything with no handler — or any
handler that cannot fully resolve its arguments — answers "I can't do that yet."

## Decisions

| Question | Decision |
|---|---|
| Scope | App-wide command bar, capabilities added phase by phase. Phase 1 = egg stock planned orders. |
| Execution | Preview, then user confirms. Never apply on parse. |
| Reads / Q&A | Out. Actions only, one result type (a proposal). |
| Navigation commands | Out of phase 1. |
| LLM config | One LLM — the company's existing `settings["llm"]`, shared with bank recon. No separate assistant model. |
| Transport | JSON-in-prompt, not native tool-use. |
| Existing planned line for same contact + date | Replace quantities; preview shows old → new. |
| Multiple commands in one phrase | Refuse: "one command at a time." |
| Contact name matches nothing | Refuse. Phase 1 does **not** create ad-hoc lines — see below. |
| `fast_parse/2` in phase 1 | Callback defined in the behaviour, **not implemented**. Ship the LLM path, measure, then add it if latency annoys. |
| Planned *purchase* lines | Out of phase 1. Sales (`planned_order`) only. |

## The core principle

**The LLM maps text to structured arguments. The database decides whether those
arguments are real.**

"Confident" is never a number the model reports. It is:

> contact resolved to exactly one row **AND** every grade name exists in this
> company **AND** the date parsed

Anything else is a refusal or a prompt for one more piece of information. This is
what makes "cannot be done right now" trustworthy rather than a vibe.

A direct consequence: **tool schemas are built per company, not written by hand.**
`EggStock.grade_names(company_id)` supplies the closed set of grade columns as a
JSON-schema `enum`, so a company with grades A/B/D cannot receive a grade "C" from
the model. Whole classes of hallucination stop being expressible instead of being
validated after the fact.

## Architecture

| Module | Responsibility |
|---|---|
| `FullCircle.Assistant` | Context facade — `parse/3`, `apply/3`. The only entry point the web layer knows. |
| `FullCircle.Assistant.Handler` | Behaviour: `tool_schema/1`, `fast_parse/2` (optional), `resolve/2`, `apply/2`, `permission/0`. |
| `FullCircle.Assistant.Registry` | Static list of handler modules; assembles per-company schemas. |
| `FullCircle.Assistant.Router` | Text + context → `{:ok, handler, args}` or `{:error, :no_match}`. |
| `FullCircle.Assistant.Proposal` | Struct: handler, summary, resolved entities, `warnings`, `blockers`, apply payload. |
| `FullCircleWeb.AssistantBarComponent` | One `live_component`: input, preview, confirm/cancel. |
| `FullCircle.Assistant.Handlers.EggStockPlannedOrder` | Phase 1 capability. |

### Control flow

```
text + page_context
  → Router (fast_parse | one LLM call)
  → handler.resolve/2        ← all DB lookups happen HERE
  → %Proposal{}
  → preview rendered; blockers make it non-submittable
  → user confirms → handler.apply/2 → flash + page updates
```

### Fast path

Each handler may implement `fast_parse/2`, a deterministic parser for the
phrasing its users type all day. A hit skips the LLM entirely — no network, no
cost, no latency. A miss falls through to the model. This is one optional
callback, not a second system, and it exists so high-volume entry does not pay a
round trip per command.

### Mounting

`live_session :require_authenticated_user_n_active_company`
(`lib/full_circle_web/router.ex:113`) is the single place that reaches every
company-scoped LiveView. An `on_mount` hook there attaches the assistant assigns;
`app.html.heex` renders the component guarded on those assigns, leaving the
print, punch, recon and logged-out layouts untouched.

### Page context

A LiveView may opt in by assigning `:assistant_context`, e.g.
`%{page: :egg_stock_day, date: ~D[2026-07-30]}`. The router passes it to the
handler. On the egg stock board this makes the date optional in the text; where a
page assigns nothing, handlers that need a date must find one in the text or
refuse.

## Phase 1 handler: egg stock planned orders

Target object: an `EggStockDayDetail` in the `planned_order` section of an
`EggStockDay`, carrying a `quantities` map keyed by **grade name**. So
"A 100, B 300, D 800" is literally `%{"A" => 100, "B" => 300, "D" => 800}`.

### Resolution

- **Contact** via `Accounting.contact_names/3` (ilike substring).
  0 matches → blocker. 1 match → resolved. **N matches → the preview renders a
  picker** and the proposal stays unsubmittable until one is chosen. Ambiguity is
  a UI state, never a guess.

  **On ad-hoc contacts.** The day board deliberately supports lines with
  `contact_id: nil` and a free-text `contact_name`, later bound to a real contact
  by `attach_contact_from_document/3`. The assistant does **not** use that in
  phase 1: a typo and a genuinely new customer are indistinguishable from the
  command text, and silently minting ad-hoc lines from misspellings would pollute
  the board and the name-matching that `sync_day_details_from_actuals/3` relies
  on. Zero matches refuses; the clerk adds an ad-hoc line by hand. Revisit once
  real refusal rates are known — the natural fix is an explicit
  "add as new name" button on the refusal preview, not an automatic fallback.
- **Grades** validated against the per-company enum.
- **Date** parsed to a `Date` (DD/MM/YYYY), falling back to page context.
- **Permission** `can?(user, :create_egg_stock_day, company)` checked at resolve
  time, so the preview says up front that you are not allowed — and **re-checked
  at apply**, because a preview can sit on screen indefinitely.

### Collision: contact already has a line that day

Replace the quantities on the existing line. The preview must label itself as an
update and show the diff per grade (`A: 80 → 100`). One line per contact per day
keeps the board readable and keeps `sync_day_details_from_actuals/3`'s
contact-matching unambiguous.

### The apply path — one writer per day

`handler.apply/2` returns a **detail attrs map, not a DB write.** Delivery is the
caller's choice, which keeps the handler pure and unit-testable:

- **Target date == the currently open board** → the bar sends the proposal to the
  parent LiveView, which calls `flush_autosave/1`, appends via `put_assoc`, and
  saves through its existing path — structurally identical to
  `handle_event("add_detail", …)`, including `position: section_count` and
  `_persistent_id: Enum.count(existing)`. The LiveView stays the sole writer.
- **Any other date**, or the bar used from another page → `EggStock.save_day/4`
  directly. No LiveView holds that day, so nothing can race.

**Why this rule exists.** `schedule_autosave/2` captures a params snapshot and
fires seconds later, and `do_save_day/2` rebuilds `clean_day` from the LiveView's
`socket.assigns.day`. A row written to the DB behind its back is *not* deleted —
`cast_assoc` only manages children present in the loaded struct, and the save path
re-preloads with `force: true` — but it is invisible until the next save, and
`position` is then computed by two counters at once, producing duplicate positions
and a line that does not appear on the board. Stale and scrambled, not destroyed.

### Two carried-over gotchas

1. **`on_replace: :delete`** on `has_many :egg_stock_day_details` means any params
   submission must carry the **full** details list. The LiveView path already
   does; a future handler that hand-builds params must not shortcut this.
2. **`cast_assoc` can miss map-only `quantities` changes** — which is exactly the
   replace case, where nothing changes but the qty map. The update path needs the
   `persist_synced_detail_quantities/3` treatment (direct update). This is the
   single most likely bug in the feature.

## Transport and shared-client changes

The `tool_schema/1` callback keeps its name — it returns a JSON schema describing
one callable action — but phase 1 does not send it through a provider's tool API.
JSON-in-prompt rather than each provider's tool API: the shared client has no
tool support, tool-calling is shaped differently for Claude-native vs
OpenAI-compatible (two implementations), and bank recon already proves
JSON-in-text works here. Native tool-use remains a later router-internal swap
with no change to the handler behaviour.

Three targeted changes to the shared LLM code, all leaving existing callers alone:

| Change | Why |
|---|---|
| `LlmClient.call/4` accepting opts | `max_tokens: 65536` suits a bank statement, not a one-object reply. Cap the assistant low as a cost-and-confusion guard; existing callers keep the current default. |
| Timeout in those opts | `http_post` hardcodes `[{:timeout, 600_000}]` — ten minutes. Unacceptable for a bar someone is waiting on. Assistant uses ~15s, then a clean "took too long." |
| Lift `decode_json/1` into a shared module | Currently private in `llm_parser.ex:340` and doing real fence-stripping salvage. Both callers need identical behaviour; duplicating it guarantees drift. |

Model cost tracking: `LlmClient.@pricing` is a hardcoded map and
`estimate_cost/3` returns `nil` for anything absent from it. Whatever model the
company configures needs a row there or assistant cost reporting is silently
blank.

## Failure handling

Every failure renders as a preview you cannot submit — never an exception, never
a partial write.

| Failure | User sees | Submittable |
|---|---|---|
| No handler matched | "I don't know how to do that yet." | No |
| Contact: 0 matches | "No contact matching 'Swee Hen'." | No |
| Contact: N matches | Understood order + picker | After picking |
| Unknown grade | "There's no grade 'C' in this company." | No |
| Unparseable date, no page context | "Which date?" | No |
| Not authorized | "You can't create egg stock entries." | No |
| Provider `none`, timeout, bad JSON | "Assistant unavailable." | No |

The two refusals are deliberately distinct. *"I don't know how to do that yet"*
means no handler matched. *"I got: Swee Heng, 30/07/2026, A:100 B:300 — but
there's no grade 'C'"* means a handler understood and could not proceed; showing
what was understood is what makes the failure fixable by the user.

## Security

Input is typed by an authenticated user, not ingested from a third party, so the
injection surface is bounded. Model output can only ever become validated
arguments to a handler that user is already permitted to run; `can?/3` is
re-checked at apply. The model is sent the command text, the page context, and
the per-company schemas — never company records — and it never writes anything.

## Testing

Deterministic seams get real unit tests:

- `resolve/2` against DB fixtures: 0 / 1 / N contact matches, unknown grade,
  unauthorized user, collision detected vs not.
- Date parsing, including DD/MM/YYYY and the page-context fallback.
- Quantity normalization (`EggStock.to_int/1`, string-keyed grade maps).
- The replace-vs-create decision and its old → new diff.
- `fast_parse/2` on its supported phrasings, and that it declines cleanly.

Prompt behaviour is **not** unit-testable — the same lesson the bank recon parser
records, where the prompts are the behaviour. Instead: a fixture file of ~20 real
phrasings clerks actually type, run manually against the configured model,
asserting on the **resolved proposal** rather than raw model output. That file is
the regression suite whenever the prompt, the schema, or the model changes.

## Out of scope for phase 1

No conversation history or multi-turn. No read queries or Q&A. No navigation
commands. No voice input. No batching several actions into one phrase. No
per-handler risk tiers — everything previews. No planned *purchase* lines. No
ad-hoc contact creation. No `fast_parse/2` implementation.

## Key files

```
lib/full_circle/assistant.ex
lib/full_circle/assistant/{handler,registry,router,proposal}.ex
lib/full_circle/assistant/handlers/egg_stock_planned_order.ex
lib/full_circle_web/components/assistant_bar_component.ex
lib/full_circle_web/components/layouts/app.html.heex   (render, guarded)
lib/full_circle_web/router.ex:113                      (on_mount)
lib/full_circle/bank_reconciliation/llm_client.ex      (opts: max_tokens, timeout)
lib/full_circle/bank_reconciliation/llm_parser.ex      (lift decode_json/1)
lib/full_circle/egg_stock.ex                           (save_day/4, grade_names/1)
lib/full_circle_web/live/egg_stock_live/form.ex        (receive proposal, flush_autosave)
test/full_circle/assistant/
```
