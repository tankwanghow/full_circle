# Tugas-in-FullCircle — Requirements Understanding

Date: 2026-08-28
Status: draft v2 — revised after design review; before spec/design approval.

## Background

- **FullCircle (FC)** is a live, multi-tenant ERP (accounting, billing, payroll,
  inventory, agricultural ops), Phoenix LiveView, company-scoped roles.
- **Tugas** is a standalone duties/todos Phoenix app (recurring duties, progress
  events with uploads, quick todos, dual Desktop+Mobile UI). It is **not deployed**;
  only 2 users, in one company, which maps to an existing FC company.
- Many FC documents and physical paper-filing workflows **start from a task or todo**
  (e.g. "pay monthly taxes"), so the task→document workflow is the primary workflow,
  not an edge case.

## Decision

**Do not merge and do not integrate the two apps.** Build Tugas-like functionality
natively inside FullCircle as a new subsystem, and retire the standalone Tugas app.
**Freeze `tugas/`** — stop treating it as a living sibling; keep it only as design
reference. No data migration.

Reasons:

- The example workflow crosses the app boundary many times; two apps would need
  permanent cross-app plumbing (tokens, write-back APIs, dangling refs, two logins).
- Evidence that legitimizes an accounting document should live in the same database
  as the document (foreign keys, one transaction, one backup, audit-friendly).
- Solo developer, light Tugas data, 1:1 entity↔company mapping — no merge blockers.

## Pain points being solved

1. **No linkage** — cannot trace task → FC document or see task status from FC.
2. **Double entry** — same information typed in Tugas and again in FC.
3. **Two systems overhead** — separate logins, tenancy, deploys.
4. **Paper filing** — physical-paper workflows have no system home.
   (Explicit paper-location tracking **deferred**; scanned evidence replaces it.)

## Core requirement

A user can **link an FC document to a duty, or vice-versa, when needed**. FC can
then **affirm a document is legit** because the duty holds all its progress events
and evidence pictures/PDFs.

### Example workflow: "Pay monthly taxes"

1. Recurring duty "Pay monthly taxes" comes due.
2. From the duty, user clicks **Make payment** → FC payment form opens with
   `?duty_id=`, user enters the payment.
3. On save, the payment↔duty link is written **in the same transaction** as the
   payment; user is returned to the duty.
4. Physical steps tracked as duty events: print payment slip → write cheque →
   boss signs → deposit to IRB.
5. Evidence uploaded on the relevant **event**: scanned/photographed bank-in slip,
   or (online variant) the IRB receipt PDF.
6. Anyone viewing the payment in FC sees the linked duty, its progress trail, and
   **the list of evidence files** (bank-in slip image, IRB receipt PDF) viewable
   in place — affirmation without leaving the document.

## Scope decisions (confirmed)

### Features (lean core)

- Recurring duties + one-off duties, due dates, progress events, complete/skip.
- Photo/PDF uploads attached to **events** (not duties directly).
- Quick todos with escalate-to-duty.
- Bidirectional duty↔document linking.
- **Dropped/deferred from Tugas:** duty types (recurrence moves onto the
  duty/series itself), urgency/countdown tiers, escalation rules beyond
  todo→duty, rich dashboard filtering, paper-file location tracking,
  completed-in-error replacement, skip-cycle, someday, holiday-aware due dates.
- **Voice-todo App API** (Tugas `POST /api/.../todos` + pairing): **keep** —
  port to FC post-v1. Not part of v1 phases.

### Access & roles (confirmed)

FC authorization is **mixed, not deny-by-default**: ~41 actions use
`forbid_roles` (which allows every role not listed), so a new role is NOT
automatically excluded from the ERP; the dashboard only special-cases
`punch_camera`, and LiveViews have no global auth on_mount.

Decisions:

- **`tasker` role: in scope — Tugas-only access.** Sees all Tugas features for
  its company, nothing else in the ERP. Cost accepted: `tasker` must be added to
  every relevant `forbid_roles` clause (or those converted to allow-lists), plus
  dashboard/nav hiding and a live_session redirect off ERP routes. This
  hardening lands in **phase 5 with the mobile shell** (tasker users are field
  users on phones) — v1 phases 1–4 ship for office roles only.
- **`auditor`: read-only** in both FC (as today) and Tugas features — view
  duties, events, evidence, links; no mutations.
- **`guest` / `disable` / `punch_camera`: nothing.**
- **Office-role tiers within Tugas** (explicit `allow_roles` lists):
  - *Everyday work* — create duties & todos, add progress events, upload
    evidence, complete/skip, escalate todo→duty:
    admin / manager / supervisor / clerk / cashier / tasker.
  - *Destructive & supervisory* — end series, correct/delete other users'
    events or attachments (own-author within 48h open to all, Tugas's rule),
    unlink/relink existing document links:
    admin / manager / supervisor only.
  - *Document linking at create time* — governed by the document's own FC
    permission: whoever can create the Payment writes the `?duty_id=` link with
    it. `tasker` sees linked doc numbers on a duty but has no click-through
    into the ERP.

### Mobile (revised — desktop first)

- v1 is **desktop**. Office staff create documents; the affirmation loop
  (duty → Payment → evidence panel) must work on desktop first.
- Mobile Tugas shell (dashboard, duty show + progress + camera upload, todos)
  comes **after** the desktop loop works. Note: "Make payment" from a phone would
  open the desktop Payment form — mobile is for progress + camera, not document
  creation.

## Design shape (pending spec approval)

Follow FC conventions throughout: `FullCircle.Tugas` context, `user_company/2`
scoping, `can?/3`, `StdInterface` logging, `uploads/<company_id>/...`. Do NOT
import Tugas's `Scope` struct or daisyUI.

### Schemas

- **`duties`** — company_id, title, description, due_date, status, created_by,
  **recurrence on the duty/series** (types are gone): `series_id`,
  `series_ended_at`, and `recur_unit` + `recur_every` (e.g. every 1 month,
  every 2 months for SST's two-month taxable period, every 3 months, yearly;
  one-off = no recurrence). **Invariant: one live cycle per `series_id`**
  (port Tugas's series model — spawn-next-on-done + end-series). Auto-create-next
  without this invariant duplicates cycles on double-submit/uncomplete.
- **`duty_events`** — duty_id, action (progress/done/skip), note, user_id,
  timestamps.
- **`duty_event_documents`** — uploads belong to **events** (Tugas's model), path
  `uploads/<company_id>/tugas/<duty_id>/<event_id>/`. Follow the existing FC
  upload gotcha (phx-change on the form).
- **`todos`** — title, note, status (open/done/cancelled), created_by, duty_id
  (set by escalate-to-duty).
- **`duty_documents`** — company_id, duty_id, doc_type, doc_no, doc_id;
  unique `(duty_id, doc_type, doc_id)`. Matches FC's doc_type/doc_no convention.
  **No real FK to the document** — needs an explicit delete/void story so a
  deleted payment does not leave a dangling link.

### Document linking

- **Whitelist, not "every document page."** v1: **Payment** only; then
  Receipt / Journal / PurInvoice. A shared live component included only on
  whitelisted forms. Print views excluded in v1.
- `?duty_id=` handled as a new `mount_new` clause in the Payment form —
  consistent with the existing `obj` (e-invoice) and `recon` (bank rec) paths.
- The `duty_documents` row is inserted **inside the document-create `Multi`**
  (pass duty_id into `BillPay.create_payment_multi/4` and later siblings) — not
  a follow-up LiveView event. Redirect back to the duty only when duty_id was
  present.
- Both duty and document pages get a picker to link/unlink existing records.
- **The document's Tugas panel lists the evidence files** of each linked duty —
  every upload across the duty's events (filename, event it belongs to, uploader,
  date), rendered as image thumbnails / PDF links, viewable in place. The
  document page is the affirmation view: seeing the bank-in slip on the Payment
  is the point, not just seeing that a duty exists.

### Phasing (linking before todos/mobile)

1. Data model incl. `duty_documents` and event attachments.
2. Duty workflow: create, due, progress events, complete, spawn next, end series.
3. **Document linking: duty → Payment → Tugas panel on Payment.**
   ← first demo: complete a tax payment from a duty and see the bank-in slip on
   the Payment.
4. Todos (+ escalate-to-duty).
5. Mobile shell + `tasker` role hardening (forbid_roles additions/conversion,
   nav hiding, live_session guard, tasker landing page).

Post-v1: voice-todo App API port (pairing + token API).

TDD, FC conventions, `mix credo`, commit per task.

## Open items (for the spec)

- Linkable document types in v1 (whitelist above — confirm).
- Behavior of `duty_documents` on document cancel / edit / delete (void story).
- Exact recurrence fields (`recur_unit` × `recur_every`) and spawn-next rules.
- Auditor read-only surface (which pages/panels).
- Fate of `tugas/` directory: frozen as reference (agreed) — archive later?
