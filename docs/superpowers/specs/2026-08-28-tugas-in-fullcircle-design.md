# Tugas-in-FullCircle — Design Spec

Date: 2026-08-28
Status: for review
Requirements: `docs/tugas-in-fullcircle-requirements.md` (v2, approved in discussion)

## 1. Overview

Build Tugas-like task functionality natively inside FullCircle as a new
subsystem, and retire the standalone `tugas/` app (frozen as design reference,
no data migration). The purpose of the subsystem is the **task→document
workflow**: an FC document (first: Payment) can be created from a duty and
linked to it in one transaction, the duty carries the progress trail and
evidence uploads (photos/PDFs), and the document page shows the linked duty
**and its evidence files** so anyone can affirm the document is legit without
leaving FullCircle.

Canonical example: recurring duty "Pay monthly taxes" → Make payment →
FC Payment saved+linked → events "printed slip / cheque signed / deposited to
IRB" → bank-in slip photo (or IRB receipt PDF) uploaded on the completing
event → Payment page shows the duty, its trail, and the slip.

## 2. Goals (v1) / Non-goals

**Goals**

1. Duties: one-off and recurring, due dates, progress events, complete/skip,
   end-series.
2. Evidence uploads attached to **events** (images + PDFs).
3. Quick todos with escalate-to-duty.
4. Bidirectional duty↔document links; v1 whitelist: **Payment**.
5. Tugas panel on whitelisted document pages listing linked duties, status,
   progress trail, and **all evidence files** (thumbnails/PDF links, viewable
   in place).
6. Roles per the agreed matrix (§6), including the `tasker` role (hardened in
   phase 5).
7. Desktop UI phases 1–4; mobile Tugas shell in phase 5.

**Non-goals (v1)**

- Duty types, urgency/countdown tiers, escalation rules beyond todo→duty,
  rich dashboard filtering, paper-file location tracking, completed-in-error
  replacement, skip-cycle, someday lists, holiday-aware due dates.
- Voice-todo App API (kept; ported post-v1: pairing + token
  `POST /api/.../todos`).
- Linking on print views.
- Assignment model (duties are company-visible, not assigned to individuals).

## 3. Conventions

Follow FullCircle conventions exclusively; do **not** port Tugas's `Scope`
struct or daisyUI.

- Context `FullCircle.Tugas` (`lib/full_circle/tugas.ex` + `lib/full_circle/tugas/`).
- Schemas `use FullCircle.Schema`; `belongs_to :company`.
- Authorization via `FullCircle.Authorization.can?/3` clauses (§6).
- Mutations through `Ecto.Multi` with `Sys.log_changeset/5` audit logging,
  matching `StdInterface` / `BillPay` patterns.
- Listing via `StdInterface.filter/6`-style similarity search + pagination.
- LiveViews under `lib/full_circle_web/live/tugas_live/`; routes inside the
  existing `scope "/companies/:company_id"` (router.ex:106).
- Note: FC's existing "Recurring" (`FullCircle.HR.Recurring`, salary
  recurrence) is unrelated — the new feature avoids that name everywhere.

## 4. Data model

All tables have `company_id` (FK to companies), UUID PKs, `timestamps`.

### `duties`

| column | type | notes |
|---|---|---|
| title | string, required | e.g. "Pay monthly taxes" |
| descriptions | text | |
| due_date | date, required | |
| status | string | `active` \| `done` \| `skipped` |
| series_id | uuid, required | same for every cycle of a recurring duty; each one-off duty gets its own |
| series_ended_at | utc_datetime, nullable | set by end-series; stops spawning |
| recur_unit | string, nullable | `day` \| `week` \| `month` \| `year`; nil = one-off |
| recur_every | integer, nullable | with unit: every 1 month, every 2 months (SST), every 3 months, every 1 year… |

**Invariant — one live cycle per series:** partial unique index
`ON duties (series_id) WHERE status = 'active'`. Completing/skipping a
recurring duty spawns the next cycle (due_date advanced by
`recur_every × recur_unit`) **in the same Multi** as the closing event; the
index makes double-submit/races impossible. End-series sets
`series_ended_at` on the live cycle and closes it without spawning.

### `duty_events`

| column | type | notes |
|---|---|---|
| duty_id | FK duties, required | |
| action | string | `progress` \| `done` \| `skip` \| `linked` \| `unlinked` \| `end_series` |
| note | text | |
| user_id | FK users, required | actor |

Events are the progress trail; `done`/`skip` events also transition the duty.
`linked`/`unlinked` events are written automatically by link operations.

### `duty_event_documents` (evidence uploads)

| column | type | notes |
|---|---|---|
| duty_event_id | FK duty_events, required | evidence is **event-scoped** |
| orig_filename | string | shown in UI |
| file_path | string | `uploads/<company_id>/tugas/<duty_id>/<event_id>/<uuid>.<ext>` |
| content_type | string | accept: jpg/jpeg/png/webp/pdf |
| size | integer | max 10 MB (matches FC's existing limit) |

Upload forms MUST bind `phx-change` (see skill `liveview-upload-gotchas`).
Files are served through an authenticated controller/plug that checks
`can?(:view_tugas)` for the company — never as public static paths.

### `todos`

| column | type | notes |
|---|---|---|
| descriptions | string, required | |
| status | string | `open` \| `done` \| `cancelled` |
| user_id | FK users, required | creator |
| closed_by_id | FK users, nullable | who done/cancelled it |
| duty_id | FK duties, nullable | set by escalate-to-duty |

Escalate-to-duty opens the duty form prefilled from the todo; on duty create,
the todo gets `duty_id` and status `done` in the same Multi.

### `duty_documents` (the duty↔document link)

| column | type | notes |
|---|---|---|
| duty_id | FK duties, required | real FK on the duty side |
| doc_type | string | e.g. `"Payment"` — FC's doc_type convention |
| doc_id | uuid | the document's id (no DB-level FK) |
| doc_no | string | e.g. `PV-1234`, denormalized for display |
| user_id | FK users | who linked |

Unique index on `(duty_id, doc_type, doc_id)`.

**Dangling-link rule:** since `doc_id` has no real FK, any document type on
the linkable whitelist MUST delete its `duty_documents` rows inside its own
delete/void Multi. For v1 this is moot — Payment has no delete path in FC
today, and edits keep `id` stable so links survive. The rule binds future
whitelist additions.

## 5. Document linking mechanics

### Create-and-link (the "Make payment" flow)

1. Duty show page: **Create document** → navigates to
   `/companies/:company_id/Payment/new?duty_id=<id>`.
2. `PaymentLive.Form.mount_new/2` gets a new clause for `%{"duty_id" => id}`,
   consistent with the existing `"obj"` (e-invoice) and `"recon"` (bank rec)
   clauses (payment_live/form.ex:37,72). It loads the duty (company-checked),
   assigns it, and prefills `descriptions` from the duty title.
3. On save, `duty_id` is passed into `BillPay.create_payment_multi/4`
   (bill_pay.ex:332) — extended with an optional duty link step that inserts
   the `duty_documents` row, a `linked` duty_event, and the Sys log **in the
   same Multi** as the payment. No follow-up LiveView event.
4. When `duty_id` was present, successful save redirects back to the duty
   show page (flash: "Payment PV-1234 created and linked"). Otherwise the
   normal redirect applies.

### Link/unlink existing records

- Duty show page: "Link document" picker — choose doc_type (whitelist) then
  search by doc_no. Writes `duty_documents` + `linked` event.
- Document form page (whitelisted types): "Link to duty" picker — search
  duties by title. Same write path. On success the flash includes a direct
  link to the duty ("Linked to *Pay monthly taxes* — open duty to record
  progress or complete it") so the user can jump straight to completing it.
- Unlink (supervisory roles only, §6) removes the row and writes an
  `unlinked` event. Links are never edited, only added/removed.

### The Tugas panel (affirmation view)

Shared live component `FullCircleWeb.TugasLive.Components.DocPanel`, included
only on whitelisted document **form/show** pages (not print views). For each
linked duty it shows:

- duty title, status, due date, link to the duty page;
- the event trail (action, note, actor, timestamp);
- **every evidence file across the duty's events**: original filename, owning
  event, uploader, date — images as thumbnails opening a lightbox/full view,
  PDFs as links opening in a new tab. Viewable in place; this panel is the
  point of the feature.

v1 whitelist: **Payment**. Next candidates (post-v1 or late v1 if trivial):
Receipt, Journal, PurInvoice — each addition is: mount clause + multi step +
panel include + delete-path rule.

## 6. Authorization

New `can?/3` clauses in `FullCircle.Authorization`, all **allow-lists**
(never `forbid_roles`, so `tasker` stays contained):

| action | roles |
|---|---|
| `:view_tugas` (duties, events, evidence, links, todos) | admin, manager, supervisor, clerk, cashier, **auditor**, **tasker** |
| `:create_duty`, `:update_duty` (live cycle, pre-close), `:add_duty_event`, `:complete_duty`, `:skip_duty`, `:upload_duty_evidence`, `:create_todo`, `:close_todo` (own), `:escalate_todo` | admin, manager, supervisor, clerk, cashier, tasker |
| `:end_duty_series`, `:correct_others_event`, `:delete_others_evidence`, `:close_others_todo`, `:unlink_duty_document` | admin, manager, supervisor |
| own-author corrections/deletes within 48 h (event note, own evidence, own todo) | the author (checked in context functions, Tugas's rule) |
| `:link_duty_document` at document create | governed by the document's own permission (e.g. `:create_payment`) — no separate check |

- `auditor`: `:view_tugas` only — sees everything, mutates nothing.
- `guest`, `disable`, `punch_camera`: nothing.
- `tasker` sees linked doc numbers on a duty but has **no click-through** into
  ERP pages (no `:view_payment` etc.).

### `tasker` hardening (phase 5)

FC authorization is mixed: ~41 actions use `forbid_roles`, which allows any
role not listed. Shipping `tasker` requires, in one phase:

1. Add `tasker` to the roles list (`Authorization.roles/0`).
2. Add `tasker` to **every** existing `forbid_roles` list (or convert those
   clauses to allow-lists) — verified count at spec time: 41.
3. Dashboard/nav: hide the ERP button grid for `tasker` (extend the existing
   `punch_camera` special-case pattern); `tasker` lands on the Tugas
   dashboard after login.
4. A live_session `on_mount` guard (or router plug) that redirects `tasker`
   off all non-Tugas routes — belt-and-braces over the `can?` checks.
5. Test: a `tasker` user walks the ERP route table and is denied everywhere
   except Tugas routes.

Until phase 5, `tasker` is not assignable (not in `roles/0`), so phases 1–4
are safe to ship without the hardening.

## 7. UI (desktop, phases 1–4)

- Nav: a **Tugas** entry in the company dashboard, gated by `:view_tugas`.
- **Duty dashboard** (`/companies/:id/tugas`) — the duty list: live cycles
  first ordered by due_date (overdue on top), then recent closed; status
  filter (active/done/skipped/all) + text search via similarity filter;
  paginated. Create buttons: **+ Duty**, **+ Todo**.
- **Duty show** (`/tugas/duties/:duty_id`) — title/status/due/recurrence
  header; event timeline with notes, uploads, and per-event evidence;
  action bar: add progress note (+ upload), complete (+ upload), skip,
  end series, create document (whitelist), link document; linked-documents
  list with doc_no click-through (role-gated).
- **Duty form** (`/tugas/duties/new`, `/tugas/duties/:id/edit`) — title,
  descriptions, due date, recurrence (`recur_every` + `recur_unit` selects;
  blank = one-off). Editing a live cycle does not touch closed cycles.
- **Todos** (`/companies/:id/tugas/todos`) — open list + done/cancelled tail;
  inline add; actions: done, cancel, escalate-to-duty.
- FC's existing UI stack and components throughout (no daisyUI).

Phase 5 adds the mobile shell: `/m/companies/:id/tugas` dashboard, duty show
with camera upload, todos; bottom-nav layout; device-detection plug with
cookie override (peggy pattern, rebuilt in FC's stack). Document *creation*
stays desktop — mobile is for progress + evidence capture.

## 8. Testing

TDD throughout; `mix precommit`-equivalent: `mix test` + `mix credo`, commit
per task.

- Context tests: recurrence invariant (double-submit cannot spawn two live
  cycles — assert on the partial unique index), spawn-on-done math for each
  unit, end-series, 48 h own-author window, todo escalation Multi,
  link/unlink writes events + logs.
- LiveView tests: duty dashboard/show/form flows; upload with
  `render_upload` (mind the LiveViewTest blind spot in
  `liveview-upload-gotchas` — assert the form binds `phx-change`);
  `?duty_id=` payment flow: payment saved ⇒ link row + `linked` event exist,
  redirect returns to duty; DocPanel renders trail + files; auditor
  read-only; role denials.
- Phase 5: tasker route-table denial test (§6).

## 9. Phasing

1. **Data model** — migrations + schemas + context CRUD for duties, events,
   event documents, todos, duty_documents; authorization clauses.
2. **Duty workflow** — dashboard, show, form; events; complete/skip/spawn;
   end-series; evidence uploads.
3. **Document linking** — `?duty_id=` mount clause, Multi step in BillPay,
   DocPanel on Payment, link/unlink pickers.
   → **First demo:** complete a tax payment from a duty and see the bank-in
   slip on the Payment.
4. **Todos** — list, inline add, close/cancel, escalate-to-duty.
5. **Mobile shell + tasker hardening** (§6, §7).

Post-v1: voice-todo App API port (pairing + token API); whitelist expansion
(Receipt, Journal, PurInvoice); paper-file location tracking if scanned
evidence proves insufficient.

## 10. Retirement of `tugas/`

Frozen immediately: no new work, no dependency updates; referenced only as
design source (series model, event documents, 48 h rules). Archive/remove
from the monorepo after phase 5 ships.
