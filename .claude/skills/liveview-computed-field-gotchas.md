---
name: liveview-computed-field-gotchas
description: Use when a readonly/computed field (e.g. Amount) in a LiveView form fails to update after editing an input, or when working with the calculatorInput JS hook — covers LiveView's focused-input patch skip and programmatic value-set event dispatch.
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

## Where this pattern lives

Forms using `calculatorInput` inputs feeding a readonly computed field: salary note
(`salary_note_live/form.ex`, `time_attend_live/salary_note_form_component.ex`), invoice,
purchase invoice, and cheque deposit forms. If users report "field X doesn't recalculate
the total but field Y does" in any of them, check tab order first.
