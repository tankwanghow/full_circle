---
name: fit-width-forms
description: Use when building or changing a FullCircle document form with a detail-line table (Invoice, PurInvoice, Receipt, Payment, CreditNote, DebitNote, or a new one) — card width, detail column widths, the ⚙ column chooser, tabs inside the card, or header field layout. Covers the fit-to-columns card, .detail-fit, contain:inline-size and .tab-hidden.
---

# Fit-to-columns document forms

The six document forms size their card to the **visible detail columns**
instead of a fixed `w-11/12` / `w-9/12`. Hiding a column with the ⚙ chooser
(`user_settings`, `Sys.get_setting/3`) makes the form narrower.

## The card and the form

```heex
<div class="w-fit min-w-[64rem] max-w-[98vw] mx-auto border rounded-lg … p-4
            [&>*:not(form)]:[contain:inline-size]">
  <.form id="object-form" class="[&>*:not(.detail-fit)]:[contain:inline-size]" …>
    …
    <.live_component module={…DetailComponent} klass="detail-fit …" … />
```

`contain: inline-size` gives an element zero intrinsic width, so **only the
detail table decides the card's width**; the header rows, banners, tab bar,
buttons and panels then fill that width. Anything new you put in the card or
the form is excluded automatically — only an element carrying `detail-fit`
sizes the card. The `min-w-[64rem]` keeps the header usable when many columns
are hidden.

## Detail columns: `.detail-fit`

Widths live in `assets/css/app.css` under `.detail-fit .detail-*-col`: numbers
and codes get fixed content widths (`flex: 0 0 Nrem`), text columns (good,
description, account) `flex: 1 0 Nrem` so they may grow. Without `.detail-fit`
the same classes are the old percentage widths.

- New detail rows use the shared `detail-*-col` classes — **no inline
  `w-[NN%]`** (CreditNote's component was converted for this reason).
- Totals-row spacers are `grow`, not `w-[82%]`.
- A column hidden by ⚙ renders with `hidden` (still in the DOM, still
  submits) — never drop it from the markup.

## Tabs inside a fit card: `.tab-hidden`, never `JS.hide` / `hidden`

`display: none` takes a panel out of width calculation, so the card would
jump in width between tabs.
Inactive panels use `.tab-hidden` (visibility hidden, zero height, no
padding/border — still counted for width, unfocusable):

```elixir
JS.remove_class("tab-hidden", to: "#receipt-details")
|> JS.add_class("tab-hidden", to: "#match-trans")
```

Panels *outside* the tabs (e.g. `#query-match-trans`) may keep
`JS.show`/`JS.hide`.

The opening tab is data-driven: `FullCircleWeb.Helpers.default_doc_tab/2`
picks the first of Details → Matchers → Cheques with a non-zero amount (else
Details), assigned once at mount as `@active_tab`. Tab and panel classes are
lists — `class={["basis-1/3 tab", @active_tab == :details && "active"]}`,
`klass={["…", @active_tab != :details && "tab-hidden"]}` (`"hidden"`, not
`tab-hidden`, for `#query-match-trans`). Never recompute `@active_tab` after
mount: tab switching is client-side `JS` class ops, and a server-side class
change would fight them.

The Matchers tab's search panel (`QryMatcherComponent`, `id="query-match-trans"`)
lives **inside the card, after the main `<.form>`** — it has its own form and
forms cannot nest — so it takes the card's width.

Notes and tasks sit **under** the card, not in it. A grid wrapper
(`mx-auto grid w-fit min-w-[64rem] max-w-[98vw]`) holds the card (still
`div.w-fit >` the title) and `RecordAside`. The aside's class includes
`[contain:inline-size]` so it fills the card's width and does not widen it.

## Header rows

Equal `grow shrink` fields squeeze the name fields once the card is narrow.

- Fields of known size get fixed widths: Reg No / Tax Id `w-36 shrink-0`,
  dates `w-[9.5rem] shrink-0`, amounts/balances `w-32`–`w-40 shrink-0`,
  E-Invoice UUID `w-[20%] min-w-[17rem]`.
- Name fields take the rest: contact `basis-64 grow shrink`, funds account
  `basis-56 grow shrink`.
- If a row still squeezes the names, **move fields to the next row without
  changing Tab order** (Receipt/Payment: Funds Amount and dates moved beside
  Descriptions; Invoice/PurInvoice: Descriptions moved to the tags row).

## Column-chooser defaults (new users only)

`UserSetting.default_settings/2` applies only when a user has no settings for
the page. Invoice/PurInvoice start with Account, Tax Rate, Discount hidden
(they come from the Good); Receipt/Payment hide Tax Rate and Discount but keep
Account (lines often post straight to an account). Existing users keep theirs.

## Checking a change

Tests (`test/full_circle_web/live/invoice_fit_layout_test.exs`) pin the
classes, but only a browser shows the layout: measure the card
(`document.querySelector('div.w-fit').getBoundingClientRect().width`), check
long values (`scrollWidth <= clientWidth` on the customer input), and switch
tabs with **real clicks** — scripted `element.click()` did not reliably fire
LiveView JS commands.
