---
name: liveview-computed-field-gotchas
description: Use when a LiveView form field misbehaves — a readonly/computed field (e.g. Amount) not updating after an edit, a virtual/display-only field rendering blank, a flash message never appearing, or work on the calculatorInput JS hook. Covers the focused-input patch skip, programmatic value-set events, _unused_* params, changeset.params fallback rendering, and the :warn flash kind.
---

# LiveView Computed-Field Gotchas

Server-side computed fields (e.g. `amount = quantity × unit_price`) are calculated in the
schema changeset on every `phx-change="validate"` (e.g. `SalaryNote.compute_fields/1` in
`lib/full_circle/HR/salary_note.ex`). If the computed value isn't showing in the form,
suspect the **client patch path**, not the server. Two known failure modes:

## 1. LiveView never patches the focused input's value

`phoenix_live_view`'s `dom_patch.ts` skips value-merging for whichever editable input
currently has focus — `mergeFocusedInput` merges attributes but **excludes `value`, even
for readonly inputs**.

Readonly inputs are still **tab-focusable**, so if a readonly computed field is next in
tab order after the field being edited, blurring (tabbing) into it silently drops the
server's recomputed value. Symptom: field A's blur updates the total, field B's doesn't —
because B is immediately before the computed field in tab order.

**Fix:** add `tabindex="-1"` to the readonly computed input (passes through `.input`'s
`:rest` globals). Clicking into the field can still reproduce the bug; rendering the value
as a plain `<div>`/text instead of an input is the bulletproof fix.

## 2. Programmatic `el.value = x` fires no events

The `calculatorInput` hook (`assets/js/app.js`) evaluates calculator expressions like
`5*3` on blur. Setting `this.el.value` programmatically does **not** dispatch an `input`
event, so `phx-change="validate"` never sees the evaluated value. After any programmatic
value set in a hook, dispatch:

```js
this.el.dispatchEvent(new Event("input", { bubbles: true }))
```

## 3. `phx-change` params carry `_unused_*` tracking keys

LiveView injects a synthetic `_unused_<field>` key into `phx-change` params
for every input the user hasn't touched — including inside nested maps like
`plan[paid_overrides][3]` (arriving as `"_unused_3" => ""`). Code that
iterates raw form maps and assumes numeric keys crashes:
`String.to_integer("_unused_1")` → `ArgumentError`, killing the LiveView.

**Fix:** parse form-map keys tolerantly (`Integer.parse`/`Decimal.parse`,
drop non-matches) and strip the `_unused_*` keys before persisting a raw
`:map` cast. Example: `FullCircle.Tax.paid_by_month/1` + `sanitize_overrides/1`
(see [[cp204-instalment-planner]]).

## 4. A virtual field renders even when it is not in the cast list

`PurInvoice` declares `:tax_id` and `:reg_no` as virtual and does **not** cast
them, yet seeding them through the attrs map makes them display. That is not an
accident: `Phoenix.HTML.FormData` for `Ecto.Changeset` falls back to
`changeset.params`, and `cast/3` keeps every key it was given there regardless
of the permitted list — only `changes` is filtered.

So a display-only mirror field is populated by **passing it in the attrs map**.
Setting it on the struct instead has no effect once params are present, and
adding it to the cast list is unnecessary. If such a field renders blank, check
whether the code that builds the attrs omitted it (this is exactly how the
e-invoice prefill first shipped with an empty Tax Id / Reg No).

## 5. Warning flashes must use `:warn`, never `:warning`

`CoreComponents.flash/1` declares `attr :kind, values: [:info, :warn, :error]`
and `flash_group/1` renders exactly those three via
`Phoenix.Flash.get(@flash, @kind)`.

Phoenix does not validate flash keys, so `put_flash(socket, :warning, msg)`
stores the message where nothing reads it — **no error, no warning, just an
invisible message**. This hid a real warning in `pur_invoice_live/form.ex`
("Could not fetch e-invoice details…") for as long as it had existed.

The flashes have no auto-hide timer — they persist until clicked — so "it
appeared and I missed it" is never the explanation. If a flash you added never
shows, check the kind before debugging anything else.

## Where this pattern lives

Forms using `calculatorInput` inputs feeding a readonly computed field: salary note
(`salary_note_live/form.ex`, `time_attend_live/salary_note_form_component.ex`), invoice,
purchase invoice, and cheque deposit forms. If users report "field X doesn't recalculate
the total but field Y does" in any of them, check tab order first.
