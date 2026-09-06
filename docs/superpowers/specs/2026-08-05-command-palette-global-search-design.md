# Command Palette — Global Document Search

**Date:** 2026-08-05  
**Status:** Implemented (search + create + groups + recents + deposit search)  
**App:** FullCircle (`full_circle`)  
**Related:** `docs/superpowers/specs/2026-07-28-assistant-command-bar-design.md` (future mode)

---

## 1. Problem & goals

Users often know a document number (from a phone call, WhatsApp, or printout) but must
navigate menus and index filters to open it. Global document jump removes that friction.

**Goals**

- App-wide **command palette** opened with **Ctrl/Cmd+K**.
- Search by **document number** (full or partial, case-insensitive).
- **v1.1:** Search by **contact name** → recent finance documents for matching contacts.
- **v1.2:** Create actions via **compound tokens** (`newinv`, `newpur`, `newcn`, …) → `/new` form.
- Select a hit → open edit form (search) or create form (action).
- Company-scoped, role-aware, fast enough while typing.
- Single shortcut **Ctrl/Cmd+K** (not two chords).
- Architecture leaves room for **assistant** and **rich query** modes later.

**Non-goals (current)**

- Natural language filters (e.g. “swee heng invoice 1/2/2026… egg grade e”)  
- LLM / assistant actions  
- Jump to contact master (only documents for that contact)  
- Master data (accounts, goods, employees) as results  
- Trading trips, payroll docs, weighings  
- Print view as primary destination  

---

## 2. Product decisions

| Question | Decision |
|----------|----------|
| Primary job | Document jump by number |
| UI | Command palette (modal), not a permanent header search box |
| Open | `Ctrl+K` / `Cmd+K`; optional header icon that opens the same modal |
| Close | `Esc`, backdrop click, or navigate away |
| Match fields | `doc_no` **or** contact `name` (documents for matching contacts) |
| Type keywords | Optional whole tokens: `inv`, `invoice`, `pinv`, `receipt`/`rc`, `payment`/`pv`, `cn`, `dn`, `journal`/`js` — filter doc types (`swee heng inv`) |
| Dates | DMY (`5/2/2026`) or ISO. **None** → no date filter. **One** → on or before (`doc_date <= d`). **Two** → inclusive range (auto-swap if inverted). Separator `-` / `to` optional. |
| Good / lines | Explicit `good <name>` or suffix matching a company good. Restricts to Invoice/PurInvoice with that good on a line. |
| Contact master | Matching contact names also yield a **Contact** hit → contact edit form (`:update_contact`). |
| Create actions | Single token only: `newinv`, `newpur`, `newrc`, `newpv`, `newcn`, `newdn`, `newjs`, `newdep`/`newdeposit`, plus longer aliases (prefix `new` lists all). Auth uses `:create_*`. |
| Action vs contact | Multi-word input never runs actions — contact “New Asia” stays search-only |
| Min query length | 2 characters |
| Match style | Case-insensitive substring (`ILIKE %terms%`); doc no ranked by `word_similarity`; contact docs by date |
| Merge | Doc-number hits first, then contact-name docs; de-dupe `{doc_type, doc_id}`; cap 20 |
| Max hits | 20 |
| Select | Arrow keys + Enter, or click → edit form |
| Auth | Only types the user can `:update_*` |
| Roles without company | Palette not shown |

### v1 document types

| Transaction `doc_type` | Edit path |
|------------------------|-----------|
| `Invoice` | `/companies/:id/Invoice/:doc_id/edit` |
| `PurInvoice` | `/companies/:id/PurInvoice/:doc_id/edit` |
| `Receipt` | `/companies/:id/Receipt/:doc_id/edit` |
| `Payment` | `/companies/:id/Payment/:doc_id/edit` |
| `CreditNote` | `/companies/:id/CreditNote/:doc_id/edit` |
| `DebitNote` | `/companies/:id/DebitNote/:doc_id/edit` |
| `Journal` | `/companies/:id/Journal/:doc_id/edit` |

### Result row

- Type label (e.g. Invoice)  
- Document number (primary)  
- Subtitle: date + contact name when present  
- Action: navigate to edit path  

---

## 3. Architecture

```
Ctrl/Cmd+K
  → CommandPaletteComponent (app layout, when company active)
       → CommandPalette.dispatch(company, user, text)
            → Router (v1: always DocNoSearch when length ≥ 2)
            → DocNoSearch queries transactions
       → render hits | empty
       → user selects → push_navigate(path)
```

### Modules

| Module | Responsibility |
|--------|----------------|
| `FullCircle.CommandPalette` | Facade: `dispatch/3` |
| `FullCircle.CommandPalette.Router` | Mode selection; extension point for assistant / rich query |
| `FullCircle.CommandPalette.Types` | Shared type specs, auth filter, hit mapping |
| `FullCircle.CommandPalette.DocNoSearch` | Match `doc_no` on transactions |
| `FullCircle.CommandPalette.ContactDocSearch` | Match contacts by name → recent docs |
| `FullCircle.CommandPalette.Hit` | Struct: type, ids, no, date, contact, label, path |
| `FullCircleWeb.CommandPaletteComponent` | Modal UI + keyboard |
| JS hook `CommandPalette` | Global Ctrl/Cmd+K; optional custom event from header |

### Data source (Approach: `transactions`)

Finance documents post to `transactions` with `doc_type`, `doc_no`, `doc_id`,
`doc_date`, `company_id`, optional `contact_id`.

- Scope with `Sys.user_company(company, user)`  
- Filter `doc_type` to the intersection of v1 set and types the user may update  
- `doc_no ILIKE %terms%`  
- `doc_id IS NOT NULL`  
- De-dupe multi-line postings: `GROUP BY doc_type, doc_id, doc_no, doc_date`  
- `contact_name` via `max(contacts.name)`  
- Order by `word_similarity(terms, doc_no) DESC`, then `doc_date DESC`  
- `LIMIT 20`  

No new search index table in v1. Add `(company_id, doc_no)` / trgm GIN later if needed.

### Authorization

Per-type update actions (existing):

- `:update_invoice`, `:update_pur_invoice`, `:update_receipt`, `:update_payment`  
- `:update_credit_note`, `:update_debit_note`, `:update_journal`  

No new permission atom in v1.

### UI mounting

Mount `CommandPaletteComponent` from **`app.html.heex`** when
`current_company` is set.

App layout is part of the LiveView tree (unlike static root chrome), so
`live_component` and events work. Print / punch / recon layouts do not mount it.

Optional: header magnifying-glass in `root.html.heex` dispatches a window
`CustomEvent` (`fc-open-command-palette`) that the component hook listens for
(root cannot use `phx-click` into the LiveView).

---

## 4. Router outcome type (future-proof)

```elixir
@type outcome ::
        {:hits, [FullCircle.CommandPalette.Hit.t()]}
        | {:proposal, term()}   # assistant later
        | {:message, String.t()}
```

**v1 Router:** trim text; if length &lt; 2 → `{:hits, []}`; else DocNoSearch → `{:hits, hits}`.

**Later modes (not built):**

1. **DocNoSearch** — bare / number-like input (current).  
2. **StructuredQuery** — “swee heng invoice 1/2/2026 - 14/2/2026 egg grade e” → filtered hit list.  
3. **Assistant handlers** — same spirit as assistant command bar design; preview → confirm apply.  

One modal only. Sections can later split **Documents** vs **Actions**. Never auto-apply
assistant proposals; search may navigate on Enter when a hit is selected.

---

## 5. UI behaviour

- Centered modal, backdrop, ~36rem max width  
- Autofocus search input  
- Placeholder: search by document number + shortcut hint  
- Highlight selected row; mouse hover updates selection  
- Footer: ↑↓ · Enter open · Esc close  
- Empty state: “No documents found”  
- Debounce input ~200–300ms (`phx-debounce`)  

---

## 6. Testing

**Context**

- Partial `doc_no` finds invoice; multi-line txn → one hit  
- Wrong company excluded  
- Unauthorized type excluded for restricted roles  
- Terms shorter than 2 → empty  
- Path maps correctly per `doc_type`  

**Optional LiveView**

- Open palette event shows modal; search fills results (if fixtures allow).  

---

## 7. Implementation order

1. `Hit`, `DocNoSearch`, `Router`, `CommandPalette` facade + context tests  
2. `CommandPaletteComponent` + mount in `app.html.heex` + JS hook  
3. Optional header trigger in root layout  
4. Manual smoke on dashboard  

---

## 8. Out of scope / follow-ups

- Rich NL query (contact + date range + good on lines)  
- Assistant command bar as palette mode  
- Masters / trading / HR documents  
- Dedicated search index table  
- Sticky LiveView in root (only if app-layout mount proves insufficient)  
