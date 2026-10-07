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
  alias FullCircle.BillPay.Payment
  alias FullCircle.EInvMetas.EInvoice
  alias FullCircle.Receipts.Extracted

  @descriptions_max 200
  @cash_account "Cash In Hand"

  def build(%Extracted{recognized: false} = ex, _com, _user, _detail_key) do
    %{
      attrs: %{descriptions: String.slice(ex.summary || "", 0, @descriptions_max)},
      warnings: ex.warnings,
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
        :supplier, source: gettext("Receipt"))

    attrs =
      attrs
      |> DocPrefill.put_goods(detail_key, com, user, :purchase)
      |> put_funds_account(ex, detail_key, com, user)

    warnings =
      (ex.warnings ++
         [
           contact_warning,
           duplicate_warning(attrs, detail_key, com),
           period_warning(ex.date, com),
           e_invoice_warning(ex.e_invoice_uuid, com)
         ])
      |> Enum.reject(&is_nil/1)

    %{
      attrs: attrs,
      warnings: warnings,
      contact_ids: {ex.supplier_tin, ex.supplier_brn},
      total: ex.total
    }
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
