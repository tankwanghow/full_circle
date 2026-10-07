defmodule FullCircle.Receipts.Extracted do
  @moduledoc """
  What the AI read off a bill or receipt, already parsed and checked by
  `Receipts.Extract`. Amounts are Decimals, dates Dates, a line's `tax_rate`
  is a percent. `recognized: false` means only `summary` is meaningful.
  """
  defstruct recognized: true,
            summary: nil,
            supplier_name: nil,
            supplier_tin: nil,
            supplier_brn: nil,
            supplier_sst_no: nil,
            doc_no: nil,
            date: nil,
            due_date: nil,
            lines: [],
            subtotal: nil,
            tax_total: nil,
            rounding: nil,
            total: nil,
            payment_method: nil,
            e_invoice_uuid: nil,
            warnings: []
end
