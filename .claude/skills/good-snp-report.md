---
name: good-snp-report
description: Use when working on the GoodSnP report (goods sales & purchases listing), FullCircle.TaggedBill report queries, the custom ilike category, or the goodsales/goodpurchases CSV exports — especially before adding or reordering columns/filters in these union queries.
---

# GoodSnP Report (Goods Sales & Purchases)

Files: `lib/full_circle/tagged_bill.ex` (queries),
`lib/full_circle_web/live/report_live/good_snp.ex` (UI),
`csv_controller.ex` (`goodsales` / `goodpurchases` branches).
Routes: `/good_snp`; legacy `/good_sales` renders the same LiveView
defaulting to Sales — keep it.

## The positional-select trap (read before touching any select map)

The four report queries are `union_all` pairs ordered with **positional**
`order_by([4, 2, 3])`. Both rely on the **written order** of the
`select: %{...}` map (Ecto preserves AST literal order — atom-sort
intuition is wrong here). Consequences:

- **New select fields go at the END of the map, in every branch of the
  union.** Inserting mid-map silently changes what `order_by([4,2,3])`
  sorts by and misaligns union columns (they pair by position, not key).
- Both branches of a union must keep identical written field order. The
  sales Invoice branch's `invoice_date:` key aligns positionally with the
  Receipt branch's `doc_date:` — result rows take keys from the **first**
  query in `union_all` (`rec` / `pay`), which is why rows expose
  `doc_date` despite the Invoice branch's key name.
- Test pin: `test/full_circle/tagged_bill_test.exs`.

## Price / amount contract

`discount` on every detail line is **signed and negative** for a reduction
(the schemas compute `good_amount = qty * unit_price + discount`). The report
must add it, never subtract:

- Line `amount = unit_price * quantity + discount`.
- Detail-row `price = amount / quantity` (net of discount — the "Avg Price"
  column is the effective unit price, not the raw `unit_price` field).
- Detail rows are **grouped per document + good + packaging + unit**
  (`group_by: [doc.id, doc_no, doc_date, cont.name, gd.name, pkg.name, gd.unit]`),
  summing `quantity`, `package_qty`, `amount`, and `string_agg(distinct
  descriptions, ' | ')`. This folds an FOC line (qty > 0, price 0) into the
  paid line for the same good so the row price is the true blended price.
  Consequence: a desc ilike filter that matches only the FOC line returns a
  row priced at 0 — the filter runs before aggregation.
- Summary `price = sum(amount) / sum(quantity)`, both in the per-branch
  `group_by` selects and in the outer union re-aggregation. Never `avg()` of
  line prices — that is unweighted and the outer union would then average
  the two branch averages again.

## Query contract

All four functions take `(contact, goods, fdate, tdate, com_id, opts \\ [])`:
`goods_sales_report`, `goods_sales_summary_report`,
`goods_purchases_report`, `goods_purchases_summary_report`.

- Sales = `Invoice`+`InvoiceDetail` ∪ cash-sale `Receipt`+`ReceiptDetail`;
  Purchases = `PurInvoice`+`PurInvoiceDetail` ∪ cash-purchase
  `Payment`+`PaymentDetail`. All four detail schemas carry
  `descriptions`, `good_id`, `package_id`, `quantity`, `package_qty`,
  `unit_price`, `discount`.
- Goods filtering is one shared `goods_condition/2` dynamic. **Binding
  convention: detail line is binding 1, Good is binding 2**
  (`[doc, detail, good | _]`) in every query — new queries must join in
  that order or the dynamic silently targets the wrong tables.
- Default (exact) mode: `goods` is a comma list of full good names;
  empty = all.
- Custom mode: `opts = [match: :ilike, name_ilike: "...", desc_ilike: "..."]`.
  Comma-separated ilike patterns; a row qualifies when good name matches
  any name pattern **OR** line descriptions match any desc pattern; a
  blank list contributes nothing; both blank = no filter. `goods` is
  ignored in this mode.

## UI / CSV notes

- The LiveView renders `price` at **4 decimals** (`precision: 4`). At 2dp,
  `Qty × Avg Price` visibly drifts from `Amount` on large quantities (a
  115k-unit row was off by ~RM500). The query result itself reconciles to
  ~1e-11. `avg_qty` is still selected (positional-union safety) but no longer
  displayed; the Qty/PackQty columns are labelled "(Sum)".

- Category select = `Product.categories() ++ ["custom"]`. Picking
  "custom" swaps the Good List textarea for two pattern textareas
  (`search[name_ilike]`, `search[desc_ilike]`); other categories
  overwrite the goods list from `get_goods_by_category`.
- Adding a column: append to select maps (see trap above), then the
  LiveView header + detail row + summary row (percent widths must total
  100 and stay aligned across the three), then `good_snp_fields()` in
  the CSV controller.
- CSV branch heads bind `= params` and read `category`/`name_ilike`/
  `desc_ilike` optionally — old bookmarked CSV URLs lack those params.
- Doc numbers render via `<.doc_link>`, which builds
  `/companies/:id/{doc_type}/{doc_id}/edit` — `doc_type` values in
  selects must be exact router path segments: `Invoice`, `PurInvoice`,
  `Receipt`, `Payment`.
