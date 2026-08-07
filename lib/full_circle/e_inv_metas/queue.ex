defmodule FullCircle.EInvMetas.Queue do
  @moduledoc """
  Received e-invoice work queue with two lanes:

  ## Purchase (`typeName == "Invoice"`)
  Supplier billed us. Stages via PurInvoice / Payment on `e_inv_uuid`:
  - **needs_bill** — no PurInvoice, no Payment
  - **billed** — PurInvoice present, no Payment
  - **paid** — Payment present

  ## Sales (`typeName == "Self-billed Invoice"`)
  Customer self-billed us (we are supplier). Stages via Invoice / Receipt:
  - **needs_invoice** — no Invoice, no Receipt
  - **invoiced** — Invoice present, no Receipt
  - **receipted** — Receipt present

  Only `status == "Valid"` and LHDN **Received** (issuer TIN ≠ company TIN).
  """

  import Ecto.Query, warn: false

  alias FullCircle.Repo
  alias FullCircle.Sys.{Company, CompanyUser}
  alias FullCircle.EInvMetas.EInvoice
  alias FullCircle.Billing.{Invoice, PurInvoice}
  alias FullCircle.BillPay.Payment
  alias FullCircle.ReceiveFund.Receipt
  alias FullCircle.Accounting

  @purchase_stages ~w(needs_bill billed paid)a
  @sales_stages ~w(needs_invoice invoiced receipted)a

  def purchase_stages, do: @purchase_stages
  def sales_stages, do: @sales_stages

  def stages_for(:purchase), do: @purchase_stages
  def stages_for(:sales), do: @sales_stages
  def stages_for(:all), do: @purchase_stages ++ @sales_stages
  def stages_for(_), do: @purchase_stages

  def default_stage(:sales), do: :needs_invoice
  def default_stage(_), do: :needs_bill

  @doc """
  List queue rows.

  Options:
    * `:lane` — `:purchase` | `:sales` | `:all` (default `:purchase`)
    * `:stage` — `:all` or a stage atom for that lane
    * `:terms`, `:days`, `:limit`, `:offset`
  """
  def list(company, user, opts \\ []) do
    lane = Keyword.get(opts, :lane, :purchase)
    stage = Keyword.get(opts, :stage, :all)
    terms = Keyword.get(opts, :terms, "") |> to_string() |> String.trim()
    days = Keyword.get(opts, :days, 45)
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    since = since_datetime(company, days)
    type_names = type_names_for(lane)

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
        left_join: inv in Invoice,
        on: inv.e_inv_uuid == ei.uuid and inv.company_id == ei.company_id,
        left_join: rc in Receipt,
        on: rc.e_inv_uuid == ei.uuid and rc.company_id == ei.company_id,
        where: ei.company_id == ^company.id,
        where: ei.status == "Valid",
        where: ei.typeName in ^type_names,
        where: ei.dateTimeReceived >= ^since
      )

    q =
      if terms == "" do
        q
      else
        like = "%#{terms}%"

        from([ei, _c, _cu, pi, pay, inv, rc] in q,
          where:
            ilike(ei.supplierName, ^like) or ilike(ei.buyerName, ^like) or
              ilike(ei.internalId, ^like) or ilike(ei.uuid, ^like) or
              ilike(ei.supplierTIN, ^like) or ilike(ei.buyerTIN, ^like) or
              ilike(pi.pur_invoice_no, ^like) or ilike(pay.payment_no, ^like) or
              ilike(inv.invoice_no, ^like) or ilike(rc.receipt_no, ^like)
        )
      end

    rows =
      from([ei, _c, _cu, pi, pay, inv, rc] in q,
        order_by: [desc: ei.dateTimeReceived],
        limit: ^limit,
        offset: ^offset,
        select: %{
          uuid: ei.uuid,
          internal_id: ei.internalId,
          supplier_name: ei.supplierName,
          supplier_tin: ei.supplierTIN,
          supplier_id: ei.issuerID,
          buyer_name: ei.buyerName,
          buyer_tin: ei.buyerTIN,
          receiver_id: ei.receiverID,
          issuer_id: ei.issuerID,
          issuer_id_type: ei.issuerIDType,
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
          payment_no: pay.payment_no,
          invoice_id: inv.id,
          invoice_no: inv.invoice_no,
          receipt_id: rc.id,
          receipt_no: rc.receipt_no
        }
      )
      |> Repo.all()
      |> Enum.map(&put_flow/1)
      |> Enum.map(&enrich_row(&1, company))
      |> Enum.map(&put_stage/1)

    case stage do
      :all -> rows
      s -> Enum.filter(rows, &(&1.stage == s))
    end
  end

  def counts(company, user, opts \\ []) do
    lane = Keyword.get(opts, :lane, :purchase)
    rows = list(company, user, Keyword.merge(opts, stage: :all, limit: 500, offset: 0))

    base =
      Enum.reduce(stages_for(lane), %{all: length(rows)}, fn s, acc ->
        Map.put(acc, s, 0)
      end)

    Enum.reduce(rows, base, fn row, acc ->
      Map.update(acc, row.stage, 1, &(&1 + 1))
    end)
  end

  def stage_label(:needs_bill), do: "Needs bill"
  def stage_label(:billed), do: "Billed"
  def stage_label(:paid), do: "Paid"
  def stage_label(:needs_invoice), do: "Needs invoice"
  def stage_label(:invoiced), do: "Invoiced"
  def stage_label(:receipted), do: "Receipted"
  def stage_label(:all), do: "All"
  def stage_label(_), do: ""

  def lane_label(:purchase), do: "Supplier bills"
  def lane_label(:sales), do: "Self-billed (sales)"
  def lane_label(:all), do: "All received"
  def lane_label(_), do: ""

  def flow_label(:purchase), do: "Purchase"
  def flow_label(:sales), do: "Sales"
  def flow_label(_), do: ""

  @doc """
  Pure stage classification. Expects `:flow` and local doc ids.
  """
  def stage_of(%{flow: :sales} = row) do
    cond do
      not is_nil(row[:receipt_id]) -> :receipted
      not is_nil(row[:invoice_id]) -> :invoiced
      true -> :needs_invoice
    end
  end

  def stage_of(row) do
    cond do
      not is_nil(row[:payment_id]) -> :paid
      not is_nil(row[:pur_invoice_id]) -> :billed
      true -> :needs_bill
    end
  end

  defp put_flow(row) do
    flow =
      case row.type_name do
        "Self-billed Invoice" -> :sales
        _ -> :purchase
      end

    Map.put(row, :flow, flow)
  end

  defp put_stage(row), do: Map.put(row, :stage, stage_of(row))

  defp type_names_for(:sales), do: ["Self-billed Invoice"]
  defp type_names_for(:purchase), do: ["Invoice"]
  defp type_names_for(:all), do: ["Invoice", "Self-billed Invoice"]
  defp type_names_for(_), do: ["Invoice"]

  defp since_datetime(company, days) do
    tz = company.timezone || "Asia/Kuala_Lumpur"

    case DateTime.now(tz) do
      {:ok, now} -> DateTime.add(now, -days, :day)
      _ -> DateTime.add(DateTime.utc_now(), -days, :day)
    end
  end

  defp enrich_row(%{flow: :sales} = row, company) do
    # Customer who self-billed us (buyer / issuer side)
    tin = row.buyer_tin || row.supplier_tin
    brn = if row.issuer_id_type == "BRN", do: row.issuer_id, else: row.receiver_id
    name = row.buyer_name || row.supplier_name

    resolve_contact(row, company, tin, brn, name, :customer)
  end

  defp enrich_row(row, company) do
    resolve_contact(
      row,
      company,
      row.supplier_tin,
      row.supplier_id,
      row.supplier_name,
      :supplier
    )
  end

  defp resolve_contact(row, company, tin, brn, name, role) do
    {contact, source} =
      case Accounting.resolve_e_invoice_contact(tin, brn, name, company) do
        {c, src} -> {c, src}
        nil -> {nil, nil}
      end

    party_name =
      case row.flow do
        :sales -> row.buyer_name || row.supplier_name
        _ -> row.supplier_name
      end

    party_tin =
      case row.flow do
        :sales -> row.buyer_tin || row.supplier_tin
        _ -> row.supplier_tin
      end

    row
    |> Map.put(:party_name, party_name)
    |> Map.put(:party_tin, party_tin)
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
    |> Map.put(:contact_role, role)
  end
end
