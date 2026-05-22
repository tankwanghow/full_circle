# Email Document Link — Design

**Date:** 2026-05-21
**Status:** Approved (design)

## Goal

Add an **Email** button to the print layout (`print_root.html.heex`) so a staff user
viewing a printable document can email it to the customer. The customer receives a
**secure, time-limited link** to view/print the document themselves — there is no PDF
attachment.

## Decisions (from brainstorming)

| Question | Decision |
|----------|----------|
| How does the customer receive the document? | A secure link, **not** a PDF attachment. No server-side PDF generation is added. |
| Which document types? | The 6 customer-facing sales documents: **Invoice, Receipt, Credit Note, Debit Note, Delivery, Order**. Internal docs (PaySlip, SalaryNote, Journal, Employee, Advance, Payment, Load, Weighing, etc.) are excluded. |
| Recipient address | Pre-fill the document contact's email, but the user **confirms/edits** it before sending. |
| Link lifetime | **30 days**, then the link shows an expired message. |
| Single vs. multi | **Single documents only.** The multi-document print pages (`print_multi`) get no Email button. |

## Background / constraints

- Print pages are plain HTML; the browser converts them to PDF via `window.print()`.
  There is no server-side PDF library, and none is being added.
- `print_root.html.heex` is a **root layout**. Elements in it (outside `@inner_content`)
  are not part of the LiveView's event tree, so `phx-click` does not work there — the
  existing Print/Close buttons are plain JS. The Email button follows that pattern.
- Print routes live in `live_session :require_authenticated_user_n_active_company_print`
  and require login + an active company. A customer has no login, so a separate public
  route is required.
- The per-document-type rendering logic (headers, detail rows, footers) lives entirely
  inside each `*.Print` LiveView module. The design reuses those modules unchanged so
  the customer sees the exact same page staff see.

## Architecture (Approach A — reuse the existing Print LiveViews)

A new **public `live_session`** exposes `/shared/<Type>/:id/print` routes that point at
the **existing** `*.Print` LiveView modules. An `on_mount` hook authenticates the
request from a signed token instead of a session, assigning `current_user` and
`current_company` so the existing `mount/3` runs unchanged.

### Token

- `Phoenix.Token`, stateless — no database table, no revocation (consistent with the
  fixed 30-day expiry decision).
- Salt: `"shared document"`.
- Payload: `%{t: doc_type, d: doc_id, c: company_id, u: user_id}` where `user_id` is
  the staff member who sent the link (used for company-scoped queries on the public
  view).
- Verified with `max_age: 2_592_000` (30 days). Expiry and tamper-detection are both
  enforced by `Phoenix.Token`.

## Components

### New files

1. **`lib/full_circle_web/shared_document.ex`**
   - `sign(doc_type, doc_id, company_id, user_id)` → signed token string.
   - `verify(token)` → `{:ok, payload}` | `{:error, reason}` (`max_age: 2_592_000`).
   - `on_mount({:verify_token, doc_type}, params, _session, socket)`:
     - Verifies `params["token"]`; checks `payload.d == params["id"]` and
       `payload.t == doc_type`.
     - On success: loads `User` + `Company`, assigns `current_user`,
       `current_company`, `shared_view?: true`; returns `{:cont, socket}`.
     - On failure: `{:halt, redirect(socket, to: "/shared/expired")}`.

2. **`lib/full_circle/document_notifier.ex`**
   - `deliver_document_link(recipient, subject, url, company)` — builds a Swoosh email
     and calls `FullCircle.Mailer.deliver/1`. Same shape as the existing
     `FullCircle.UserAccounts.UserNotifier`.
   - `from`: the `:mail_from` application env (falls back to the current default),
     consistent with `UserNotifier`.
   - `reply_to`: `company.email`, so customer replies reach the company.
   - Text body: short greeting, the link, and a note that it expires in 30 days.

3. **`lib/full_circle_web/controllers/document_email_controller.ex`**
   - `POST /email_document` — authenticated, active company.
   - Params: `doc_type`, `id`, `email` (recipient), `doc_no` (display only).
   - Validates `doc_type` is one of the 6 allowed types.
   - Loads the document via `StdInterface.get!(schema, id, company, user)` as an
     access check (out-of-company / missing → error response).
   - Signs a token; builds the public URL
     `url(~p"/shared/#{doc_type}/#{id}/print?pre_print=false&token=…")`.
   - Calls `DocumentNotifier`; responds JSON `{ok: true}` or
     `{ok: false, error: message}`.

4. **`lib/full_circle_web/controllers/shared_document_controller.ex`** (+ minimal
   template) — `GET /shared/expired`: a plain page stating the link has expired or is
   no longer valid and to contact the company for a new copy.

### Modified files

5. **`lib/full_circle_web/components/layouts/print_root.html.heex`**
   - An `Email` `<a>` next to the existing Print/Close links, rendered
     `:if={assigns[:email_doc] && !assigns[:shared_view?]}`.
   - Carries `data-type`, `data-id`, `data-doc-no`, `data-email` from the `@email_doc`
     assign, plus a CSRF token.
   - Plain-JS `emailDocument(el)`: `prompt()` pre-filled with the contact email →
     `fetch` POST to `/email_document` with the CSRF header → `alert()` the result.
     Aborts before POST if the prompt is blank/cancelled.

6. **`lib/full_circle_web/router.ex`**
   - New public `live_session :public_shared_document`: no auth on_mount,
     `root_layout: {FullCircleWeb.Layouts, :print_root}`,
     `on_mount: [{FullCircleWeb.SharedDocument, {:verify_token, "<Type>"}},
     {FullCircleWeb.Locale, :set_locale}]`.
   - Six routes `/shared/Invoice/:id/print` … `/shared/Order/:id/print` pointing at the
     existing `InvoiceLive.Print`, `ReceiptLive.Print`, `CreditNoteLive.Print`,
     `DebitNoteLive.Print`, `DeliveryLive.Print`, `OrderLive.Print`.
   - `POST /email_document` (authenticated pipeline) and `GET /shared/expired`.

7. **Six Print LiveViews** — `InvoiceLive.Print`, `ReceiptLive.Print`,
   `CreditNoteLive.Print`, `DebitNoteLive.Print`, `DeliveryLive.Print`,
   `OrderLive.Print`:
   - In the **single-id `mount` clause only** (`%{"id" => id, ...}`), add
     `assign(:email_doc, %{type: "<Type>", id: id, doc_no: doc_no, email:
     doc.contact.email})`.
   - The multi-document `mount` clause (`%{"ids" => ...}`) is left unchanged → no
     button on multi-print.
   - `render/1` and all rendering functions are **untouched** — `print_root` reads the
     `@email_doc` assign directly.

## Data flow

**Sending**

1. Staff opens a single-document print page (e.g. `/Invoice/:id/print?pre_print=false`).
2. `mount/3` assigns `email_doc`; `print_root` renders the Email button.
3. Staff clicks Email → `prompt()` pre-filled with the contact's email → staff
   confirms/edits the recipient.
4. JS `fetch`-POSTs `{doc_type, id, doc_no, email}` to `/email_document`.
5. Controller authorizes, signs the token, builds the `/shared/...` URL, sends the
   email; returns JSON. JS shows an `alert()` with success or the error.

**Viewing**

1. Customer opens the emailed `/shared/<Type>/:id/print?pre_print=false&token=…` link.
2. The `:public_shared_document` session runs `SharedDocument.on_mount`, which verifies
   the token and assigns `current_user`/`current_company` from it plus
   `shared_view?: true`.
3. The existing `*.Print` `mount/3` runs unchanged and renders the identical document.
   The Email button is hidden because `shared_view?` is true.
4. A bad/expired/tampered token → redirect to `/shared/expired`.

## Error handling

- Invalid / expired / tampered token → `/shared/expired` (signature + `max_age`
  enforced by `Phoenix.Token`).
- POST for a document outside the user's company → `StdInterface.get!` fails → JSON
  error → `alert()`.
- Blank/cancelled recipient prompt → JS aborts before POST.
- Mailer failure → `{:error, message}` → JSON error → `alert()`.
- Unauthenticated POST to `/email_document` → handled by the authenticated pipeline
  (redirect to login).

## Testing

- **`SharedDocument`**: `sign` → `verify` round-trip; expired token (`max_age`)
  rejected; tampered token rejected; wrong doc-type/id rejected.
- **`DocumentEmailController`**: authenticated user emails an accessible document and
  an email is sent (asserted via `Swoosh.Adapters.Test`); a cross-company document
  returns an error; an invalid `doc_type` returns an error; an unauthenticated request
  is redirected.
- **`DocumentNotifier`**: produces an email with the correct `to`, `from`, subject and
  a body containing the link.
- **Public route**: `/shared/Invoice/:id/print?token=…` renders the invoice with a
  valid token; redirects to `/shared/expired` with an invalid one.

## Out of scope

- Server-side PDF generation / PDF attachments.
- Multi-document (`print_multi`) emailing.
- The 8 non-sales document types.
- Link revocation / a tracked-tokens table (stateless token, 30-day expiry only).
- Deploy tooling changes (the email transport is the SMTP setup already in place).
