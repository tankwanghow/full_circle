defmodule FullCircle.EInvMetas do
  import Ecto.Query, warn: false

  alias FullCircle.Sys.{Company, CompanyUser}
  alias FullCircle.Accounting.Contact
  alias FullCircle.Billing.{Invoice, PurInvoice}
  alias FullCircle.Billing
  alias FullCircle.BillPay.Payment
  alias FullCircle.DebCre.{DebitNote, CreditNote}
  alias FullCircle.ReceiveFund.Receipt
  alias FullCircle.EInvMetas.{EInvMeta, EInvoice}
  alias FullCircle.Repo

  def get_by_company_id!(com_id, user_id) do
    meta =
      from(ei in EInvMeta,
        join: c in Company,
        on: c.id == ei.company_id,
        join: cu in CompanyUser,
        on: cu.company_id == c.id,
        where: ei.company_id == ^com_id,
        where: cu.user_id == ^user_id
      )
      |> FullCircle.Repo.one()

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

  def get_internal_document("PurInvoice", "Received", einv, com, user) do
    doc =
      get_internal_doc_by_uuid(PurInvoice, einv.uuid, com.id) ||
        get_internal_doc_by_uuid(PurInvoice, einv.internalId, com.id)

    if is_nil(doc) do
      {:not_found, %PurInvoice{}, %Payment{}}
    else
      {:ok, Billing.get_pur_invoice!(doc.id, com, user)}
    end
  end

  def get_internal_document("Invoice", "Sent", einv, com, user) do
    doc =
      get_internal_doc_by_uuid(Invoice, einv.uuid, com.id) ||
        get_internal_doc_by_uuid(Invoice, einv.internalId, com.id)

    if is_nil(doc) do
      {:not_found, %Invoice{}, %Receipt{}}
    else
      {:ok, Billing.get_invoice!(doc.id, com, user)}
    end
  end

  def get_internal_document("Credit Note", "Received", einv, com_id) do
    doc =
      get_internal_doc_query(
        DebitNote,
        einv.uuid,
        :e_inv_internal_id,
        einv.internalId,
        com_id
      )

    {doc,
     get_internal_doc_url(
       "DebitNote",
       doc,
       set_dir_main_name(einv, "Received", einv.supplierName),
       com_id
     )}
  end

  defp get_internal_doc_query(klass, x, y, z, p) do
  end

  def get_internal_document("Credit Note", "Sent", einv, com_id) do
    doc =
      get_internal_doc_query(CreditNote, einv.uuid, :note_no, einv.internalId, com_id)

    {doc,
     get_internal_doc_url(
       "CreditNote",
       doc,
       set_dir_main_name(einv, "Sent", einv.buyerName),
       com_id
     )}
  end

  def get_internal_document("Debit Note", "Received", einv, com_id) do
    doc =
      get_internal_doc_query(
        CreditNote,
        einv.uuid,
        :e_inv_internal_id,
        einv.internalId,
        com_id
      )

    {doc,
     get_internal_doc_url(
       "CreditNote",
       doc,
       set_dir_main_name(einv, "Received", einv.supplierName),
       com_id
     )}
  end

  def get_internal_document("Debit Note", "Sent", einv, com_id) do
    doc =
      get_internal_doc_query(DebitNote, einv.uuid, :note_no, einv.internalId, com_id)

    {doc,
     get_internal_doc_url(
       "DebitNote",
       doc,
       set_dir_main_name(einv, "Sent", einv.buyerName),
       com_id
     )}
  end

  def get_internal_document("Refund Note", "Received", einv, com_id) do
    doc =
      get_internal_doc_query(
        Receipt,
        einv.uuid,
        :e_inv_internal_id,
        einv.internalId,
        com_id
      )

    {doc,
     get_internal_doc_url(
       "Receipt",
       doc,
       set_dir_main_name(einv, "Received", einv.supplierName),
       com_id
     )}
  end

  def get_internal_document("Refund Note", "Sent", einv, com_id) do
    doc =
      get_internal_doc_query(Payment, einv.uuid, :payment_no, einv.internalId, com_id)

    {doc,
     get_internal_doc_url(
       "Payment",
       doc,
       set_dir_main_name(einv, "Sent", einv.buyerName),
       com_id
     )}
  end

  def get_internal_document("Self-billed Invoice", "Received", einv, com_id) do
    doc =
      get_internal_doc_query(
        Invoice,
        einv.uuid,
        :e_inv_internal_id,
        einv.internalId,
        com_id
      )

    {doc,
     get_internal_doc_url(
       "Invoice",
       doc,
       set_dir_main_name(einv, "Received", einv.buyerName),
       com_id
     )}
  end

  def get_internal_document("Self-billed Invoice", "Sent", einv, com_id) do
    doc =
      get_internal_doc_query(
        PurInvoice,
        einv.uuid,
        :e_inv_internal_id,
        einv.internalId,
        com_id
      )

    {doc,
     get_internal_doc_url(
       "PurInvoice",
       doc,
       set_dir_main_name(einv, "Sent", einv.supplierName),
       com_id
     )}
  end

  def get_internal_document("Self-billed Credit Note", "Received", einv, com_id) do
    doc =
      get_internal_doc_query(
        CreditNote,
        einv.uuid,
        :e_inv_internal_id,
        einv.internalId,
        com_id
      )

    {doc,
     get_internal_doc_url(
       "CreditNote",
       doc,
       set_dir_main_name(einv, "Received", einv.buyerName),
       com_id
     )}
  end

  def get_internal_document("Self-billed Credit Note", "Sent", einv, com_id) do
    doc =
      get_internal_doc_query(DebitNote, einv.uuid, :note_no, einv.internalId, com_id)

    {doc,
     get_internal_doc_url(
       "DebitNote",
       doc,
       set_dir_main_name(einv, "Sent", einv.supplierName),
       com_id
     )}
  end

  def get_internal_document("Self-billed Debit Note", "Received", einv, com_id) do
    doc =
      get_internal_doc_query(
        DebitNote,
        einv.uuid,
        :e_inv_internal_id,
        einv.internalId,
        com_id
      )

    {doc,
     get_internal_doc_url(
       "DebitNote",
       doc,
       set_dir_main_name(einv, "Received", einv.buyerName),
       com_id
     )}
  end

  def get_internal_document("Self-billed Debit Note", "Sent", einv, com_id) do
    doc =
      get_internal_doc_query(CreditNote, einv.uuid, :note_no, einv.internalId, com_id)

    {doc,
     get_internal_doc_url(
       "CreditNote",
       doc,
       set_dir_main_name(einv, "Sent", einv.supplierName),
       com_id
     )}
  end

  def get_internal_document("Self-billed Refund Note", "Received", einv, com_id) do
    doc =
      get_internal_doc_query(
        Payment,
        einv.uuid,
        :e_inv_internal_id,
        einv.internalId,
        com_id
      )

    {doc,
     get_internal_doc_url(
       "Payment",
       doc,
       set_dir_main_name(einv, "Received", einv.buyerName),
       com_id
     )}
  end

  def get_internal_document("Self-billed Refund Note", "Sent", einv, com_id) do
    doc =
      get_internal_doc_query(Receipt, einv.uuid, :receipt_no, einv.internalId, com_id)

    {doc,
     get_internal_doc_url(
       "Receipt",
       doc,
       set_dir_main_name(einv, "Sent", einv.supplierName),
       com_id
     )}
  end

  defp get_internal_doc_by_uuid(klass, uuid, com_id) do
    from(inv in klass,
      where: inv.e_inv_uuid == ^uuid,
      where: inv.company_id == ^com_id
    )
    |> Repo.one()
  end

  defp get_internal_doc_by_internal_id(klass, iid, com_id) do
    from(inv in klass,
      where: inv.e_inv_interal_id == ^iid,
      where: inv.company_id == ^com_id
    )
    |> Repo.one()
  end

  defp get_internal_doc_url(doc_type, doc, einv, com_id) when is_nil(doc) do
    "/companies/#{com_id}/#{doc_type}/new?obj=#{Jason.encode!(einv)}"
  end

  defp get_internal_doc_url(doc_type, doc, einv, com_id) do
    if doc.e_inv_uuid do
      "/companies/#{com_id}/#{doc_type}/#{doc.id}/unmatch_e_inv"
    else
      "/companies/#{com_id}/#{doc_type}/#{doc.id}/match_e_inv?obj=#{Jason.encode!(einv)}"
    end
  end

  def get_e_invoices(sd, ed, per_page, page, com_id, user_id) do
    from(ei in EInvoice,
      join: c in Company,
      on: c.id == ei.company_id,
      join: cu in CompanyUser,
      on: cu.company_id == c.id,
      where: ei.company_id == ^com_id,
      where: cu.user_id == ^user_id,
      where: ei.dateTimeReceived >= ^sd,
      where: ei.dateTimeReceived <= ^ed,
      limit: ^per_page,
      offset: (^page - 1) * ^per_page,
      select: ei,
      order_by: [desc: ei.dateTimeReceived]
    )
    |> FullCircle.Repo.all()
  end

  def get_e_invoices_from_cloud(sd, ed, com_id, user_id) do
    meta = get_by_company_id!(com_id, user_id)

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

  def e_invoice_last_sync_datetime(com_id, user_id) do
    from(ei in EInvoice,
      join: c in Company,
      on: c.id == ei.company_id,
      join: cu in CompanyUser,
      on: cu.company_id == c.id,
      where: ei.company_id == ^com_id,
      where: cu.user_id == ^user_id,
      select: max(ei.dateTimeReceived)
    )
    |> FullCircle.Repo.one() || ~U[2024-07-01 00:00:00Z]
  end

  def sync_e_invoices(com_id, user_id) do
    last_sync = e_invoice_last_sync_datetime(com_id, user_id) |> DateTime.add(-3, :day)

    now = DateTime.utc_now()
    range = get_date_range(last_sync, now) |> Enum.chunk_every(2, 1, :discard)

    Enum.each(range, fn [a, b] ->
      lt =
        get_e_invoices_from_cloud(
          Timex.format!(a, "%Y-%m-%dT%H:%M:%S", :strftime),
          Timex.format!(b, "%Y-%m-%dT%H:%M:%S", :strftime),
          com_id,
          user_id
        )
        |> Enum.map(fn x -> Map.merge(x, %{"company_id" => com_id}) end)
        |> Enum.map(fn x -> EInvoice.changeset(%EInvoice{}, x) end)
        |> Enum.map(fn x -> x.changes end)

      IO.inspect("EInvoice from #{a} to #{b} is #{Enum.count(lt)}")

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
    IO.inspect({baseurl, path, path_params, search_qry})

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

  defp set_dir_main_name(einv, dir, name) do
    Map.merge(einv, %{fc_direction: dir, fc_mainName: name})
  end
end
