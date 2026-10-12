defmodule FullCircle.Receipts.Prefill do
  @moduledoc """
  `%Extracted{}` → attrs for a new Payment or PurInvoice, plus advisory
  warnings. Contact and goods follow `DocPrefill` (identifiers first, goods
  only when safe). Nothing here blocks a save. Contract:
  `.claude/skills/receipt-capture.md`.
  """
  import Ecto.Query, warn: false
  use Gettext, backend: FullCircleWeb.Gettext

  alias FullCircle.{Accounting, BillPay, DocPrefill, Repo, Sys}
  alias FullCircle.Billing.PurInvoice
  alias FullCircle.BillPay.{Payment, PaymentDetail}
  alias FullCircle.EInvMetas.EInvoice
  alias FullCircle.Receipts.Extracted

  @descriptions_max 200
  @cash_account "Cash In Hand"
  @max_receipts 40

  @doc """
  A read's documents → one seed. Only recognised documents count. One seeds
  as before; a PurInvoice takes the first; a Payment with 2+ gets one line
  per receipt and no payee (`build_many/3`) — for a claim the payee is the
  claimant, not the shops.
  """
  def build(docs, com, user, detail_key) when is_list(docs) do
    {known, unknown} = Enum.split_with(docs, & &1.recognized)
    dropped = dropped_warning(known, unknown)

    case {known, detail_key} do
      {[], _} ->
        build(List.first(docs) || not_recognised(), com, user, detail_key)

      {[one], _} ->
        one |> build(com, user, detail_key) |> add_warnings(dropped)

      {[first | _], :pur_invoice_details} ->
        first
        |> build(com, user, detail_key)
        |> add_warnings([only_first_warning(length(known)) | dropped])

      {many, :payment_details} ->
        many |> build_many(com, user) |> add_warnings(dropped)
    end
  end

  def build(%Extracted{recognized: false} = ex, _com, _user, _detail_key) do
    %{
      attrs: %{descriptions: String.slice(ex.summary || "", 0, @descriptions_max)},
      warnings: ex.warnings,
      duplicate: nil,
      learn: nil,
      contact_ids: {nil, nil},
      total: nil
    }
  end

  def build(%Extracted{} = ex, com, user, detail_key) do
    {attrs, contact_warning} =
      %{detail_key => DocPrefill.seed_lines(ex.lines ++ extra_lines(ex))}
      |> Map.merge(header(ex, detail_key))
      |> DocPrefill.put_contact(
        ex.supplier_tin,
        ex.supplier_brn,
        ex.supplier_name,
        com,
        :supplier,
        source: gettext("Receipt")
      )

    attrs =
      attrs
      |> DocPrefill.put_goods(detail_key, com, user, :purchase)
      |> put_funds_account(ex, detail_key, com, user)

    warnings =
      (ex.warnings ++
         [
           contact_warning,
           period_warning(ex.date, com),
           e_invoice_warning(ex.e_invoice_uuid, com)
         ])
      |> Enum.reject(&is_nil/1)

    %{
      attrs: attrs,
      warnings: warnings,
      # Re-checked by the form against whatever contact the clerk ends up with.
      duplicate: duplicate_warning(attrs, detail_key, com),
      # Identifiers are learnt only onto the contact they themselves matched
      # (a name match proves nothing about the read TIN).
      learn:
        if(attrs[:contact_id] && is_nil(contact_warning),
          do: {attrs.contact_id, ex.supplier_tin, ex.supplier_brn}
        ),
      contact_ids: {ex.supplier_tin, ex.supplier_brn},
      total: ex.total
    }
  end

  defp not_recognised,
    do: %Extracted{recognized: false, warnings: [gettext("Not recognised as a bill or receipt.")]}

  defp add_warnings(seed, []), do: seed
  defp add_warnings(seed, extra), do: %{seed | warnings: seed.warnings ++ extra}

  defp dropped_warning([], _unknown), do: []
  defp dropped_warning(_known, []), do: []

  defp dropped_warning(_known, unknown),
    do: [
      ngettext(
        "%{count} document in the file could not be read as a receipt.",
        "%{count} documents in the file could not be read as receipts.",
        length(unknown)
      )
    ]

  defp only_first_warning(n),
    do:
      gettext(
        "The file shows %{n} bills — only the first was used. One Purchase Invoice per bill.",
        n: n
      )

  # 2+ receipts on a Payment (a claim): one line per receipt, payee left for
  # the clerk. The first @max_receipts in read order are used, then sorted by date.
  defp build_many(docs, com, user) do
    {used, over} = Enum.split(docs, @max_receipts)
    # Shop names in read order (descriptions); lines in date order.
    shops = used |> Enum.map(& &1.supplier_name) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    used = sort_by_date(used)
    dates = used |> Enum.map(& &1.date) |> Enum.reject(&is_nil/1)
    pay_date = if dates == [], do: nil, else: Enum.max(dates, Date)
    total = Enum.reduce(used, Decimal.new(0), &Decimal.add(&1.total || 0, &2))
    method = if Enum.all?(used, &(&1.payment_method == "cash")), do: "cash"

    attrs =
      %{
        payment_details: used |> Enum.map(&receipt_line/1) |> DocPrefill.seed_lines(),
        payment_date: pay_date,
        funds_amount: total,
        descriptions: many_descriptions(length(used), shops)
      }
      |> put_funds_account(%{payment_method: method}, :payment_details, com, user)

    warnings =
      [payee_warning(length(used), length(shops))] ++
        span_warning(dates, pay_date) ++
        over_warning(length(used) + length(over)) ++
        repeated_warnings(used) ++
        Enum.flat_map(used, &receipt_warnings(&1, com))

    %{
      attrs: attrs,
      warnings: warnings,
      duplicate: nil,
      learn: nil,
      contact_ids: {nil, nil},
      total: total
    }
  end

  # ISO strings sort by date (Date structs compare structurally); undated last,
  # read order breaks ties.
  defp sort_by_date(docs) do
    docs
    |> Enum.with_index()
    |> Enum.sort_by(fn {d, i} -> {if(d.date, do: Date.to_iso8601(d.date), else: "9999"), i} end)
    |> Enum.map(&elem(&1, 0))
  end

  defp receipt_line(doc) do
    amount = doc.total || Decimal.new(0)

    %{
      descriptions: line_text(doc),
      quantity: Decimal.new(1),
      unit_price: amount,
      discount: Decimal.new(0),
      tax_rate: nil,
      amount: amount
    }
  end

  # The kind leads the line: the "<Kind> · " prefix is also the key
  # learnt_goods/2 looks up, so kind labels are never translated.
  defp line_text(%{kind: nil} = doc), do: receipt_text(doc, true)
  defp line_text(doc), do: doc.kind <> " · " <> receipt_text(doc, true)

  # "<shop> #<doc_no> <DD/MM/YYYY>", parts not read left out.
  defp receipt_text(doc, with_date?) do
    [
      doc.supplier_name,
      doc.doc_no && "#" <> doc.doc_no,
      with_date? && doc.date && Calendar.strftime(doc.date, "%d/%m/%Y")
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> case do
      [] -> gettext("Receipt")
      parts -> Enum.join(parts, " ")
    end
  end

  defp many_descriptions(n, []), do: gettext("%{n} receipts", n: n)

  defp many_descriptions(n, shops),
    do:
      String.slice(
        gettext("%{n} receipts: %{shops}", n: n, shops: Enum.join(shops, ", ")),
        0,
        @descriptions_max
      )

  defp payee_warning(n, 0),
    do: gettext("%{n} receipts — pick the payee (e.g. the salesperson).", n: n)

  defp payee_warning(n, shops),
    do:
      ngettext(
        "%{n} receipts from %{count} shop — pick the payee (e.g. the salesperson).",
        "%{n} receipts from %{count} shops — pick the payee (e.g. the salesperson).",
        shops,
        n: n
      )

  defp span_warning([], _pay_date), do: []

  defp span_warning(dates, pay_date) do
    first = Enum.min(dates, Date)

    if Date.compare(first, pay_date) == :eq,
      do: [],
      else: [
        gettext("Receipts are dated %{first} to %{last}; the pay date was set to %{last}.",
          first: Calendar.strftime(first, "%d/%m/%Y"),
          last: Calendar.strftime(pay_date, "%d/%m/%Y")
        )
      ]
  end

  defp over_warning(n) when n > @max_receipts,
    do: [
      gettext(
        "%{n} receipts read; only the first %{max} were used. Split the claim into two Payments.",
        n: n,
        max: @max_receipts
      )
    ]

  defp over_warning(_n), do: []

  defp receipt_warnings(doc, com) do
    label = receipt_text(doc, false)
    no_total = if is_nil(doc.total), do: gettext("no total read — its line is 0.00.")

    (doc.warnings ++
       [no_total, period_warning(doc.date, com), e_invoice_warning(doc.e_invoice_uuid, com)])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&"#{label}: #{&1}")
    |> Kernel.++(List.wrap(claimed_warning(doc, com)))
  end

  @doc """
  An earlier Payment line that already claims this receipt — its text holds
  "#<doc_no>" as a whole word and its amount is within 0.01 — or nil.
  Relies on the line text `build_many/3` writes; advisory only.
  """
  def claimed_warning(%Extracted{doc_no: no, total: %Decimal{} = total} = doc, com)
      when is_binary(no) do
    # A bound regex parameter: metacharacters in the receipt no are escaped,
    # and "#12" must not match "#123".
    pattern = "#" <> Regex.escape(no) <> "(\\s|$)"

    from(d in PaymentDetail,
      join: p in Payment,
      on: p.id == d.payment_id,
      where: p.company_id == ^com.id,
      where: fragment("? ~* ?", d.descriptions, ^pattern),
      where:
        fragment(
          "abs(round(? * ? + ?, 2) - ?) < 0.01",
          d.quantity,
          d.unit_price,
          d.discount,
          ^total
        ),
      order_by: p.payment_no,
      select: p.payment_no,
      limit: 1
    )
    |> Repo.one()
    |> case do
      nil ->
        nil

      payment_no ->
        gettext("%{receipt} (RM %{amount}) may already be claimed on %{doc}.",
          receipt: receipt_text(doc, false),
          amount: Decimal.round(total, 2),
          doc: payment_no
        )
    end
  end

  def claimed_warning(_doc, _com), do: nil

  # The same receipt photographed twice, or on two scanned pages.
  defp repeated_warnings(docs) do
    docs
    |> Enum.filter(&(&1.doc_no && &1.total))
    |> Enum.group_by(
      &{&1.supplier_name, &1.doc_no, Decimal.to_string(Decimal.round(&1.total, 2))}
    )
    |> Enum.filter(fn {_key, group} -> length(group) > 1 end)
    |> Enum.map(fn {_key, [doc | _]} ->
      gettext("%{receipt} appears more than once in this file.",
        receipt: receipt_text(doc, false)
      )
    end)
  end

  defp header(ex, :payment_details) do
    %{payment_date: ex.date, funds_amount: ex.total, descriptions: payment_descriptions(ex)}
  end

  defp header(ex, :pur_invoice_details) do
    # e_inv_internal_id is the supplier's own bill number; pur_invoice_no is
    # our gapless PINV number and is never seeded.
    %{pur_invoice_date: ex.date, due_date: ex.due_date || ex.date, e_inv_internal_id: ex.doc_no}
  end

  defp payment_descriptions(ex) do
    [ex.supplier_name, ex.doc_no && "#" <> ex.doc_no]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> case do
      "" -> nil
      s -> String.slice(s, 0, @descriptions_max)
    end
  end

  # This company books SST as its own line; a rounding adjustment needs its
  # own account. Both leave the good blank for the clerk.
  defp extra_lines(ex) do
    sst =
      if positive?(ex.tax_total) and
           Enum.all?(ex.lines, &(is_nil(&1.tax_rate) or Decimal.eq?(&1.tax_rate, 0))),
         do: [extra_line(gettext("SST"), ex.tax_total)],
         else: []

    rounding =
      if ex.rounding && not Decimal.eq?(ex.rounding, 0),
        do: [extra_line(gettext("Rounding adj."), ex.rounding)],
        else: []

    sst ++ rounding
  end

  defp extra_line(descr, amount),
    do: %{
      descriptions: descr,
      quantity: Decimal.new(1),
      unit_price: amount,
      discount: Decimal.new(0),
      tax_rate: nil,
      amount: amount
    }

  defp positive?(%Decimal{} = d), do: Decimal.gt?(d, 0)
  defp positive?(_), do: false

  # Sole funds account (98.7% right on history), else Cash In Hand for a cash
  # receipt, else blank.
  defp put_funds_account(attrs, ex, :payment_details, com, user) do
    name =
      (attrs[:contact_id] && BillPay.sole_funds_account_name(attrs.contact_id, com)) ||
        if(ex.payment_method == "cash", do: @cash_account)

    case name && Accounting.get_account_by_name(name, com, user) do
      nil ->
        attrs

      account ->
        Map.merge(attrs, %{funds_account_name: account.name, funds_account_id: account.id})
    end
  end

  defp put_funds_account(attrs, _ex, _detail_key, _com, _user), do: attrs

  @doc "A possible-duplicate warning for these (seed attrs or form params), or nil."
  def duplicate_warning(attrs, :pur_invoice_details, com) do
    with contact_id when contact_id not in [nil, ""] <- get(attrs, :contact_id),
         doc_no when doc_no not in [nil, ""] <- get(attrs, :e_inv_internal_id),
         no when not is_nil(no) <-
           Repo.one(
             from p in PurInvoice,
               where:
                 p.company_id == ^com.id and p.contact_id == ^contact_id and
                   p.e_inv_internal_id == ^doc_no,
               select: p.pur_invoice_no,
               limit: 1
           ) do
      gettext("Possible duplicate: %{doc} has the same supplier and bill no.", doc: no)
    else
      _ -> nil
    end
  end

  def duplicate_warning(attrs, :payment_details, com) do
    with contact_id when contact_id not in [nil, ""] <- get(attrs, :contact_id),
         %Date{} = date <- to_date(get(attrs, :payment_date)),
         %Decimal{} = amount <- DocPrefill.to_decimal(get(attrs, :funds_amount)),
         no when not is_nil(no) <-
           Repo.one(
             from p in Payment,
               where:
                 p.company_id == ^com.id and p.contact_id == ^contact_id and
                   p.payment_date == ^date and p.funds_amount == ^amount,
               select: p.payment_no,
               limit: 1
           ) do
      gettext("Possible duplicate: %{doc} has the same supplier, date and amount.", doc: no)
    else
      _ -> nil
    end
  end

  defp get(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp to_date(%Date{} = d), do: d

  defp to_date(s) when is_binary(s) do
    case Date.from_iso8601(s) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp to_date(_), do: nil

  defp period_warning(nil, _com), do: nil

  defp period_warning(date, com) do
    case Sys.period_closed_through(com) do
      %Date{} = closed ->
        if Date.compare(date, closed) != :gt,
          do:
            gettext("Date %{d} is in a closed accounting period (closed through %{c}).",
              d: date,
              c: closed
            ),
          else: nil

      _ ->
        nil
    end
  end

  defp e_invoice_warning(nil, _com), do: nil

  defp e_invoice_warning(uuid, com) do
    if Repo.exists?(from e in EInvoice, where: e.company_id == ^com.id and e.uuid == ^uuid),
      do:
        gettext(
          "This bill has an e-invoice (%{uuid}). Create it from the E-Invoice list instead.",
          uuid: uuid
        ),
      else: nil
  end
end
