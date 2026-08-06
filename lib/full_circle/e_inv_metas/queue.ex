defmodule FullCircle.EInvMetas.Queue do
  @moduledoc """
  Received supplier e-invoice work queue: needs bill → billed → paid.

  Scope: LHDN **Received** rows with `typeName == "Invoice"` and `status == "Valid"`.
  Self-billed invoices are excluded (they drive the outbound Payment/Invoice flow).

  Staging uses local documents linked by `e_inv_uuid`:
  - **needs_bill** — no PurInvoice and no Payment
  - **billed** — PurInvoice present, no Payment
  - **paid** — Payment present (with or without PurInvoice)
  """

  import Ecto.Query, warn: false

  alias FullCircle.Repo
  alias FullCircle.Sys.{Company, CompanyUser}
  alias FullCircle.EInvMetas.EInvoice
  alias FullCircle.Billing.PurInvoice
  alias FullCircle.BillPay.Payment
  alias FullCircle.Accounting

  @stages ~w(needs_bill billed paid)a

  def stages, do: @stages

  @doc """
  List queue rows for the company. `stage` is `:all` or one of `stages/0`.
  """
  def list(company, user, opts \\ []) do
    stage = Keyword.get(opts, :stage, :all)
    terms = Keyword.get(opts, :terms, "") |> to_string() |> String.trim()
    days = Keyword.get(opts, :days, 45)
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    tz = company.timezone || "Asia/Kuala_Lumpur"

    since =
      case DateTime.now(tz) do
        {:ok, now} -> DateTime.add(now, -days, :day)
        _ -> DateTime.add(DateTime.utc_now(), -days, :day)
      end

    q =
      from(ei in EInvoice,
        join: c in Company,
        on: c.id == ei.company_id and c.tax_id != ei.issuerTIN,
        join: cu in CompanyUser,
        on: cu.company_id == c.id and cu.user_id == ^user.id,
        left_join: pi in PurInvoice,
        on: pi.e_inv_uuid == ei.uuid and pi.company_id == ei.company_id,
        left_join: pay in Payment,
        on: pay.e_inv_uuid == ei.uuid and pay.company_id == ei.company_id,
        where: ei.company_id == ^company.id,
        where: ei.status == "Valid",
        where: ei.typeName == "Invoice",
        where: ei.dateTimeReceived >= ^since
      )

    q =
      if terms == "" do
        q
      else
        like = "%#{terms}%"

        from([ei, _c, _cu, pi, pay] in q,
          where:
            ilike(ei.supplierName, ^like) or ilike(ei.internalId, ^like) or
              ilike(ei.uuid, ^like) or ilike(ei.supplierTIN, ^like) or
              ilike(pi.pur_invoice_no, ^like) or ilike(pay.payment_no, ^like)
        )
      end

    rows =
      from([ei, _c, _cu, pi, pay] in q,
        order_by: [desc: ei.dateTimeReceived],
        limit: ^limit,
        offset: ^offset,
        select: %{
          uuid: ei.uuid,
          internal_id: ei.internalId,
          supplier_name: ei.supplierName,
          supplier_tin: ei.supplierTIN,
          supplier_id: ei.issuerID,
          amount: ei.totalPayableAmount,
          currency: ei.documentCurrency,
          status: ei.status,
          type_name: ei.typeName,
          issued_at: ei.dateTimeIssued,
          received_at: ei.dateTimeReceived,
          long_id: ei.longId,
          pur_invoice_id: pi.id,
          pur_invoice_no: pi.pur_invoice_no,
          payment_id: pay.id,
          payment_no: pay.payment_no
        }
      )
      |> Repo.all()
      |> Enum.map(&enrich_row(&1, company))
      |> Enum.map(&put_stage/1)

    case stage do
      :all -> rows
      s when s in @stages -> Enum.filter(rows, &(&1.stage == s))
      _ -> rows
    end
  end

  @doc """
  Counts per stage (and total) for the same filters as `list/3` (without stage filter).
  """
  def counts(company, user, opts \\ []) do
    rows = list(company, user, Keyword.merge(opts, stage: :all, limit: 500, offset: 0))

    base = %{all: length(rows), needs_bill: 0, billed: 0, paid: 0}

    Enum.reduce(rows, base, fn row, acc ->
      Map.update(acc, row.stage, 1, &(&1 + 1))
    end)
  end

  def stage_label(:needs_bill), do: "Needs bill"
  def stage_label(:billed), do: "Billed"
  def stage_label(:paid), do: "Paid"
  def stage_label(:all), do: "All"
  def stage_label(_), do: ""

  @doc """
  Pure stage classification from linked local document ids.
  """
  def stage_of(%{payment_id: pay_id}) when not is_nil(pay_id), do: :paid
  def stage_of(%{pur_invoice_id: pi_id}) when not is_nil(pi_id), do: :billed
  def stage_of(_), do: :needs_bill

  defp put_stage(row), do: Map.put(row, :stage, stage_of(row))

  defp enrich_row(row, company) do
    {contact, source} =
      case Accounting.resolve_e_invoice_contact(
             row.supplier_tin,
             row.supplier_id,
             row.supplier_name,
             company
           ) do
        {c, src} -> {c, src}
        nil -> {nil, nil}
      end

    row
    |> Map.put(:contact_id, contact && contact.id)
    |> Map.put(:contact_name, contact && contact.name)
    |> Map.put(:contact_source, source)
    |> Map.put(
      :blocker,
      cond do
        is_nil(contact) -> :no_contact
        source == :name -> :name_match
        true -> nil
      end
    )
  end
end
