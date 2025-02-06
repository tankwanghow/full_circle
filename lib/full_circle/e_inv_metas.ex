defmodule FullCircle.EInvMetas do
  import Ecto.Query, warn: false

  alias FullCircle.Sys.{Company, CompanyUser, Log}
  alias FullCircle.Accounting.{Contact, Transaction}
  alias FullCircle.Billing.{Invoice, PurInvoice}
  alias FullCircle.BillPay.Payment
  alias FullCircle.DebCre.{DebitNote, CreditNote}
  alias FullCircle.ReceiveFund.Receipt
  alias FullCircle.EInvMetas.{EInvMeta, EInvoice}
  alias FullCircle.Repo
  alias Ecto.Multi

  def get_by_company_id!(com, user) do
    meta =
      from(ei in EInvMeta,
        join: c in Company,
        on: c.id == ei.company_id,
        join: cu in CompanyUser,
        on: cu.company_id == c.id,
        where: ei.company_id == ^com.id,
        where: cu.user_id == ^user.id
      )
      |> Repo.one()

    cond do
      is_nil(meta) ->
        nil

      is_nil(meta.token) ->
        {:ok, meta} = refresh_e_invoice_token(meta)
        meta

      Timex.shift(meta.updated_at, seconds: 3000) |> Timex.compare(Timex.now()) < 0 ->
        {:ok, meta} = refresh_e_invoice_token(meta)
        meta

      true ->
        meta
    end
  end

  defp get_internal_doc_by_uuid(klass, einv, amount, com) do
    from(inv in klass,
      join: txn in Transaction,
      on: txn.doc_id == inv.id,
      join: cont in Contact,
      on: inv.contact_id == cont.id and txn.company_id == ^com.id,
      where: inv.e_inv_uuid == ^einv.uuid,
      where: fragment("abs(?) = round(?, 2)", txn.amount, ^amount),
      distinct: true,
      select: %{
        priority: 1,
        e_inv_uuid: inv.e_inv_uuid,
        e_inv_internal_id: inv.e_inv_internal_id,
        doc_id: txn.doc_id,
        doc_no: txn.doc_no,
        doc_date: txn.doc_date,
        doc_type: txn.doc_type,
        contact_name: cont.name,
        contact_tin: cont.tax_id,
        amount: fragment("abs(?)", txn.amount)
      }
    )
  end

  defp get_internal_doc_by_doc_no(klass, field, einv, amount, com) do
    from(inv in klass,
      join: txn in Transaction,
      on: txn.doc_id == inv.id,
      join: cont in Contact,
      on: inv.contact_id == cont.id and txn.company_id == ^com.id,
      where: field(inv, ^field) == ^einv.internalId,
      where: is_nil(inv.e_inv_uuid),
      where: fragment("abs(?) = round(?, 2)", txn.amount, ^amount),
      distinct: true,
      select: %{
        priority: 2,
        e_inv_uuid: inv.e_inv_uuid,
        e_inv_internal_id: inv.e_inv_internal_id,
        doc_id: txn.doc_id,
        doc_no: txn.doc_no,
        doc_date: txn.doc_date,
        doc_type: txn.doc_type,
        contact_name: cont.name,
        contact_tin: cont.tax_id,
        amount: fragment("abs(?)", txn.amount)
      }
    )
  end

  defp get_internal_doc_by_contact(
         klass,
         einv,
         contact_field,
         amount,
         com
       ) do
    clean_contact =
      String.replace(Map.get(einv, contact_field), ~r/[^a-zA-Z0-9]/, "")
      |> String.slice(0..15)
      |> String.downcase()

    clean_contact = "%#{clean_contact}%"

    sd = einv.dateTimeReceived |> DateTime.to_date() |> Date.shift(day: -10)
    ed = einv.dateTimeReceived |> DateTime.to_date() |> Date.shift(day: 10)

    from(inv in klass,
      join: txn in Transaction,
      on: txn.doc_id == inv.id,
      join: cont in Contact,
      on: inv.contact_id == cont.id and txn.company_id == ^com.id,
      where:
        fragment("abs(?) = round(?, 2)", txn.amount, ^amount) and
          ilike(
            fragment(
              "lower(left(regexp_replace(?, '[^a-zA-Z0-9]', '', 'g'), 16))",
              cont.name
            ),
            ^clean_contact
          ),
      where: txn.doc_date >= ^sd,
      where: txn.doc_date <= ^ed,
      where: is_nil(inv.e_inv_uuid),
      distinct: true,
      select: %{
        priority: 3,
        e_inv_uuid: inv.e_inv_uuid,
        e_inv_internal_id: inv.e_inv_internal_id,
        doc_id: txn.doc_id,
        doc_no: txn.doc_no,
        doc_date: txn.doc_date,
        doc_type: txn.doc_type,
        contact_name: cont.name,
        contact_tin: cont.tax_id,
        amount: fragment("abs(?)", txn.amount)
      }
    )
  end

  defp get_fc_doc(klass, einv, doc_no_field, contact_field, com) do
    amount =
      if(Decimal.gt?(einv.totalPayableAmount, einv.totalNetAmount),
        do: einv.totalPayableAmount,
        else: einv.totalNetAmount
      )

    q1 = get_internal_doc_by_uuid(klass, einv, amount, com)
    q2 = get_internal_doc_by_doc_no(klass, doc_no_field, einv, amount, com)
    q3 = get_internal_doc_by_contact(klass, einv, contact_field, amount, com)

    fq = q1 |> union(^q2) |> union(^q3)

    r = Repo.all(fq)

    min =
      cond do
        r == [] -> 0
        true -> Enum.min_by(r, fn x -> x.priority end).priority
      end

    r = r |> Enum.filter(fn x -> x.priority == min end)

    if r == [], do: nil, else: r
  end

  def get_internal_document("Invoice", "Sent", einv, com) do
    get_fc_doc(Invoice, einv, :invoice_no, :buyerName, com) ||
      get_fc_doc(Receipt, einv, :receipt_no, :buyerName, com) || []
  end

  def get_internal_document("Self-billed Invoice", "Sent", einv, com) do
    get_fc_doc(PurInvoice, einv, :e_inv_internal_id, :supplierName, com) ||
      get_fc_doc(Payment, einv, :payment_no, :supplierName, com) || []
  end

  def get_internal_document("Invoice", "Received", einv, com) do
    get_fc_doc(PurInvoice, einv, :e_inv_internal_id, :supplierName, com) ||
      get_fc_doc(Payment, einv, :payment_no, :supplierName, com) || []
  end

  def get_internal_document("Self-billed Invoice", "Received", einv, com) do
    get_fc_doc(Invoice, einv, :invoice_no, :buyerName, com) ||
      get_fc_doc(Receipt, einv, :receipt_no, :buyerName, com) || []
  end

  def get_internal_document("Credit Note", "Sent", einv, com) do
    get_fc_doc(CreditNote, einv, :note_no, :buyerName, com) || []
  end

  def get_internal_document("Debit Note", "Sent", einv, com) do
    get_fc_doc(DebitNote, einv, :note_no, :buyerName, com) || []
  end

  def get_internal_document("Credit Note", "Received", einv, com) do
    get_fc_doc(DebitNote, einv, :note_no, :supplierName, com) || []
  end

  def get_internal_document("Debit Note", "Received", einv, com) do
    get_fc_doc(CreditNote, einv, :note_no, :supplierName, com) || []
  end

  def get_e_invs(uuid, internal_id, contact_field, contact, amount, doc_date, com, user) do
    q1 = get_e_invoices_by_uuid(uuid, amount, com, user)
    q2 = get_e_invoices_by_internal_id(internal_id, amount, com, user)
    q3 = get_e_invoices_by_contact(contact_field, contact, amount, doc_date, com, user)

    fq = q1 |> union(^q2) |> union(^q3)

    r = Repo.all(fq)

    min =
      cond do
        r == [] -> 0
        true -> Enum.min_by(r, fn x -> x.priority end).priority
      end

    r = r |> Enum.filter(fn x -> x.priority == min end)

    if r == [], do: nil, else: r
  end

  defp get_e_invoices_by_uuid(uuid, amount, com, user) do
    from(ei in EInvoice,
      join: c in Company,
      on: c.id == ei.company_id and c.tax_id == ei.issuerTIN,
      join: cu in CompanyUser,
      on: cu.company_id == c.id,
      where: ei.uuid == ^uuid,
      distinct: true,
      where: ei.totalPayableAmount == ^amount or ei.totalNetAmount == ^amount,
      select: %{
        rejectRequestDateTime: ei.rejectRequestDateTime,
        intermediaryROB: ei.intermediaryROB,
        totalExcludingTax: ei.totalExcludingTax,
        uuid: ei.uuid,
        totalNetAmount: ei.totalNetAmount,
        supplierTIN: ei.supplierTIN,
        issuerTIN: ei.issuerTIN,
        receiverIDType: ei.receiverIDType,
        internalId: ei.internalId,
        status: ei.status,
        documentStatusReason: ei.documentStatusReason,
        longId: ei.longId,
        submissionChannel: ei.submissionChannel,
        buyerTIN: ei.buyerTIN,
        issuerID: ei.issuerID,
        supplierName: ei.supplierName,
        issuerIDType: ei.issuerIDType,
        totalPayableAmount: ei.totalPayableAmount,
        dateTimeValidated: ei.dateTimeValidated,
        typeName: ei.typeName,
        buyerName: ei.buyerName,
        intermediaryTIN: ei.intermediaryTIN,
        dateTimeReceived: ei.dateTimeReceived,
        receiverTIN: ei.receiverTIN,
        dateTimeIssued: ei.dateTimeIssued,
        submissionUid: ei.submissionUid,
        cancelDateTime: ei.cancelDateTime,
        documentCurrency: ei.documentCurrency,
        receiverID: ei.receiverID,
        receiverName: ei.receiverName,
        typeVersionName: ei.typeVersionName,
        createdByUserId: ei.createdByUserId,
        intermediaryName: ei.intermediaryName,
        totalDiscount: ei.totalDiscount,
        priority: 1
      }
    )
  end

  defp get_e_invoices_by_internal_id(internal_id, amount, com, user) do
    from(ei in EInvoice,
      join: c in Company,
      on: c.id == ei.company_id and c.tax_id == ei.issuerTIN,
      join: cu in CompanyUser,
      on: cu.company_id == c.id,
      where: ei.internalId == ^internal_id,
      distinct: true,
      where: ei.totalPayableAmount == ^amount or ei.totalNetAmount == ^amount,
      select: %{
        rejectRequestDateTime: ei.rejectRequestDateTime,
        intermediaryROB: ei.intermediaryROB,
        totalExcludingTax: ei.totalExcludingTax,
        uuid: ei.uuid,
        totalNetAmount: ei.totalNetAmount,
        supplierTIN: ei.supplierTIN,
        issuerTIN: ei.issuerTIN,
        receiverIDType: ei.receiverIDType,
        internalId: ei.internalId,
        status: ei.status,
        documentStatusReason: ei.documentStatusReason,
        longId: ei.longId,
        submissionChannel: ei.submissionChannel,
        buyerTIN: ei.buyerTIN,
        issuerID: ei.issuerID,
        supplierName: ei.supplierName,
        issuerIDType: ei.issuerIDType,
        totalPayableAmount: ei.totalPayableAmount,
        dateTimeValidated: ei.dateTimeValidated,
        typeName: ei.typeName,
        buyerName: ei.buyerName,
        intermediaryTIN: ei.intermediaryTIN,
        dateTimeReceived: ei.dateTimeReceived,
        receiverTIN: ei.receiverTIN,
        dateTimeIssued: ei.dateTimeIssued,
        submissionUid: ei.submissionUid,
        cancelDateTime: ei.cancelDateTime,
        documentCurrency: ei.documentCurrency,
        receiverID: ei.receiverID,
        receiverName: ei.receiverName,
        typeVersionName: ei.typeVersionName,
        createdByUserId: ei.createdByUserId,
        intermediaryName: ei.intermediaryName,
        totalDiscount: ei.totalDiscount,
        priority: 2
      }
    )
  end

  defp get_e_invoices_by_contact(einv_contact_field, contact, amount, doc_date, com, user) do
    clean_contact =
      String.replace(contact, ~r/[^a-zA-Z0-9]/, "")
      |> String.slice(0..15)
      |> String.downcase()

    sd = doc_date |> Timex.to_datetime() |> DateTime.shift(day: -10)
    ed = doc_date |> Timex.to_datetime() |> DateTime.shift(day: 10)

    from(ei in EInvoice,
      join: c in Company,
      on: c.id == ei.company_id and c.tax_id == ei.issuerTIN,
      join: cu in CompanyUser,
      on: cu.company_id == c.id,
      distinct: true,
      where: ei.totalPayableAmount == ^amount or ei.totalNetAmount == ^amount,
      where:
        ilike(
          fragment(
            "lower(left(regexp_replace(?, '[^a-zA-Z0-9]', '', 'g'), 16))",
            field(ei, ^einv_contact_field)
          ),
          ^"%#{clean_contact}%"
        ),
      select: %{
        rejectRequestDateTime: ei.rejectRequestDateTime,
        intermediaryROB: ei.intermediaryROB,
        totalExcludingTax: ei.totalExcludingTax,
        uuid: ei.uuid,
        totalNetAmount: ei.totalNetAmount,
        supplierTIN: ei.supplierTIN,
        issuerTIN: ei.issuerTIN,
        receiverIDType: ei.receiverIDType,
        internalId: ei.internalId,
        status: ei.status,
        documentStatusReason: ei.documentStatusReason,
        longId: ei.longId,
        submissionChannel: ei.submissionChannel,
        buyerTIN: ei.buyerTIN,
        issuerID: ei.issuerID,
        supplierName: ei.supplierName,
        issuerIDType: ei.issuerIDType,
        totalPayableAmount: ei.totalPayableAmount,
        dateTimeValidated: ei.dateTimeValidated,
        typeName: ei.typeName,
        buyerName: ei.buyerName,
        intermediaryTIN: ei.intermediaryTIN,
        dateTimeReceived: ei.dateTimeReceived,
        receiverTIN: ei.receiverTIN,
        dateTimeIssued: ei.dateTimeIssued,
        submissionUid: ei.submissionUid,
        cancelDateTime: ei.cancelDateTime,
        documentCurrency: ei.documentCurrency,
        receiverID: ei.receiverID,
        receiverName: ei.receiverName,
        typeVersionName: ei.typeVersionName,
        createdByUserId: ei.createdByUserId,
        intermediaryName: ei.intermediaryName,
        totalDiscount: ei.totalDiscount,
        priority: 3
      }
    )
  end

  def get_e_invoices(sd, ed, per_page, page, com, user, "Sent", terms) do
    from(ei in EInvoice,
      join: c in Company,
      on: c.id == ei.company_id and c.tax_id == ei.issuerTIN,
      join: cu in CompanyUser,
      on: cu.company_id == c.id,
      where: ilike(ei.uuid, ^"%#{terms}%"),
      or_where: ilike(ei.internalId, ^"%#{terms}%"),
      or_where: ilike(ei.supplierName, ^"%#{terms}%"),
      or_where: ilike(ei.buyerName, ^"%#{terms}%"),
      or_where: ilike(ei.supplierTIN, ^"%#{terms}%"),
      or_where: ilike(ei.buyerTIN, ^"%#{terms}%"),
      or_where: ilike(ei.typeName, ^"%#{terms}%"),
      where: ei.company_id == ^com.id,
      where: cu.user_id == ^user.id,
      where: ei.dateTimeReceived >= ^sd,
      where: ei.dateTimeReceived <= ^ed,
      limit: ^per_page,
      offset: (^page - 1) * ^per_page,
      select: ei,
      order_by: [desc: ei.dateTimeReceived]
    )
    |> Repo.all()
  end

  def get_e_invoices(sd, ed, per_page, page, com, user, "Received", terms) do
    from(ei in EInvoice,
      join: c in Company,
      on: c.id == ei.company_id and c.tax_id != ei.issuerTIN,
      join: cu in CompanyUser,
      on: cu.company_id == c.id,
      where: ilike(ei.uuid, ^"%#{terms}%"),
      or_where: ilike(ei.internalId, ^"%#{terms}%"),
      or_where: ilike(ei.supplierName, ^"%#{terms}%"),
      or_where: ilike(ei.buyerName, ^"%#{terms}%"),
      or_where: ilike(ei.supplierTIN, ^"%#{terms}%"),
      or_where: ilike(ei.buyerTIN, ^"%#{terms}%"),
      or_where: ilike(ei.typeName, ^"%#{terms}%"),
      where: ei.company_id == ^com.id,
      where: cu.user_id == ^user.id,
      where: ei.dateTimeReceived >= ^sd,
      where: ei.dateTimeReceived <= ^ed,
      limit: ^per_page,
      offset: (^page - 1) * ^per_page,
      select: ei,
      order_by: [desc: ei.dateTimeReceived]
    )
    |> Repo.all()
  end

  defp get_e_invoices_from_cloud(sd, ed, com, user) do
    meta = get_by_company_id!(com, user)

    meta_url =
      build_e_inv_url(meta.e_inv_idsrvbaseurl, meta.search_url, [],
        submissionDateFrom: sd,
        submissionDateTo: ed,
        pageSize: 1,
        pageNo: 1
      )

    %{"metadata" => %{"totalCount" => total_count}, "result" => _} =
      Req.get!(meta_url, headers: [Authorization: meta.token]).body

    pages = (total_count / 100) |> Float.ceil() |> trunc()

    Enum.map(1..pages, fn p ->
      url =
        build_e_inv_url(meta.e_inv_idsrvbaseurl, meta.search_url, [],
          submissionDateFrom: sd,
          submissionDateTo: ed,
          pageSize: 100,
          pageNo: p
        )

      %{"metadata" => _, "result" => res} =
        Req.get!(url, headers: [Authorization: meta.token]).body

      res
    end)
    |> List.flatten()
  end

  def e_invoice_last_sync_datetime(com, user) do
    from(ei in EInvoice,
      join: c in Company,
      on: c.id == ei.company_id,
      join: cu in CompanyUser,
      on: cu.company_id == c.id,
      where: ei.company_id == ^com.id,
      where: cu.user_id == ^user.id,
      select: max(ei.dateTimeReceived)
    )
    |> FullCircle.Repo.one() || ~U[2024-07-01 00:00:00Z]
  end

  def sync_e_invoices(com, user) do
    last_sync = e_invoice_last_sync_datetime(com.id, user.id) |> DateTime.add(-3, :day)

    now = DateTime.utc_now()
    range = get_date_range(last_sync, now) |> Enum.chunk_every(2, 1, :discard)

    Enum.each(range, fn [a, b] ->
      lt =
        get_e_invoices_from_cloud(
          Timex.format!(a, "%Y-%m-%dT%H:%M:%S", :strftime),
          Timex.format!(b, "%Y-%m-%dT%H:%M:%S", :strftime),
          com.id,
          user.id
        )
        |> Enum.map(fn x -> Map.merge(x, %{"company_id" => com.id}) end)
        |> Enum.map(fn x -> EInvoice.changeset(%EInvoice{}, x) end)
        |> Enum.map(fn x -> x.changes end)

      Repo.insert_all(EInvoice, lt,
        on_conflict: :replace_all,
        conflict_target: [:uuid],
        returning: true
      )
    end)
  end

  defp get_date_range(a, b) do
    if DateTime.add(a, 60 * 60 * 24 * 2, :second) |> DateTime.compare(b) == :gt do
      [a, DateTime.add(a, Integer.mod(DateTime.diff(b, a), 60 * 60 * 24 * 2), :second)]
    else
      [a, get_date_range(DateTime.add(a, 60 * 60 * 24 * 2, :second), b)] |> List.flatten()
    end
  end

  defp refresh_e_invoice_token(meta) do
    url = build_e_inv_url(meta.e_inv_idsrvbaseurl, meta.login_url)

    try do
      result =
        Req.post!(url,
          form: [
            client_id: meta.e_inv_clientid,
            client_secret: meta.e_inv_clientsecret1,
            grant_type: "client_credentials",
            scope: "InvoicingAPI"
          ]
        ).body

      case result do
        %{"access_token" => token} ->
          update_token(meta, token)

        _ ->
          result
      end
    rescue
      _ -> {:ok, meta}
    end
  end

  defp update_token(meta, token) do
    meta
    |> Ecto.Changeset.change(%{token: token})
    |> Repo.update()
  end

  def build_e_inv_url(baseurl, path, path_params \\ [], search_qry \\ []) do
    path =
      Enum.reduce(path_params, path, fn {k, v}, path ->
        String.replace(path, "{#{Atom.to_string(k)}}", v)
      end)

    search_qry =
      search_qry
      |> Enum.map_join("&", fn {k, v} ->
        "#{k |> Atom.to_string()}=#{v}"
      end)

    "https://#{baseurl}#{path}?#{search_qry}"
  end

  def match(einv, fc_doc, com, user) do
    match(fc_doc["doc_type"], einv, fc_doc, com, user)
  end

  defp match("Receipt", einv, fc_doc, com, user) do
    match(Receipt, einv, fc_doc, com, user)
  end

  defp match("Invoice", einv, fc_doc, com, user) do
    match(Invoice, einv, fc_doc, com, user)
  end

  defp match("PurInvoice", einv, fc_doc, com, user) do
    match(PurInvoice, einv, fc_doc, com, user)
  end

  defp match("Payment", einv, fc_doc, com, user) do
    match(Payment, einv, fc_doc, com, user)
  end

  defp match("CreditNote", einv, fc_doc, com, user) do
    match(CreditNote, einv, fc_doc, com, user)
  end

  defp match("DebitNote", einv, fc_doc, com, user) do
    match(DebitNote, einv, fc_doc, com, user)
  end

  defp match(klass, einv, fc_doc, com, user) do
    Multi.new()
    |> Multi.update_all(
      :matching,
      from(doc in klass,
        where: doc.id == ^fc_doc["doc_id"],
        update: [set: [e_inv_uuid: ^einv["uuid"], e_inv_internal_id: ^einv["internalId"]]]
      ),
      []
    )
    |> Multi.insert(:logging, %Log{
      entity: klass.__schema__(:source),
      entity_id: fc_doc["doc_id"],
      action: "update",
      delta: "Note: Matched to e-Invoice #{einv["uuid"]}",
      user_id: user.id,
      company_id: com.id
    })
    |> Repo.transaction()
  end

  def unmatch(fc_doc, com, user) do
    unmatch(fc_doc["doc_type"], fc_doc, com, user)
  end

  defp unmatch("Receipt", fc_doc, com, user) do
    unmatch(Receipt, fc_doc, com, user)
  end

  defp unmatch("Invoice", fc_doc, com, user) do
    unmatch(Invoice, fc_doc, com, user)
  end

  defp unmatch("PurInvoice", fc_doc, com, user) do
    unmatch(PurInvoice, fc_doc, com, user)
  end

  defp unmatch("Payment", fc_doc, com, user) do
    unmatch(Payment, fc_doc, com, user)
  end

  defp unmatch("CreditNote", fc_doc, com, user) do
    unmatch(CreditNote, fc_doc, com, user)
  end

  defp unmatch("DebitNote", fc_doc, com, user) do
    unmatch(DebitNote, fc_doc, com, user)
  end

  defp unmatch(klass, fc_doc, com, user) do
    Multi.new()
    |> Multi.update_all(
      :unmatching,
      from(doc in klass,
        where: doc.id == ^fc_doc["doc_id"],
        update: [set: [e_inv_uuid: nil, e_inv_internal_id: nil]]
      ),
      []
    )
    |> Multi.insert(:logging, %Log{
      entity: klass.__schema__(:source),
      entity_id: fc_doc["doc_id"],
      action: "update",
      delta: "Note: Unmatched from e-Invoice #{fc_doc["uuid"]}",
      user_id: user.id,
      company_id: com.id
    })
    |> Repo.transaction()
  end
end
