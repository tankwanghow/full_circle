defmodule FullCircle.EInvMetas do
  import Ecto.Query, warn: false

  alias FullCircle.Sys.{Company, CompanyUser}
  alias FullCircle.Billing.{Invoice, PurInvoice}
  alias FullCircle.BillPay.Payment
  alias FullCircle.DebCre.{DebitNote, CreditNote}
  alias FullCircle.ReceiveFund.Receipt
  alias FullCircle.EInvMetas.{EInvMeta}
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

  def get_internal_document("Invoice", "Received", einv, com_id) do
    doc =
      get_internal_doc_query(
        PurInvoice,
        einv["uuid"],
        :e_inv_internal_id,
        einv["internalId"],
        com_id
      )

    {doc,
     get_internal_doc_url(
       "PurInvoice",
       doc,
       set_dir_main_name(einv, "Received", einv["supplierName"]),
       com_id
     )}
  end

  def get_internal_document("Invoice", "Sent", einv, com_id) do
    doc =
      get_internal_doc_query(Invoice, einv["uuid"], :invoice_no, einv["internalId"], com_id)

    {doc,
     get_internal_doc_url(
       "Invoice",
       doc,
       set_dir_main_name(einv, "Sent", einv["buyerName"]),
       com_id
     )}
  end

  def get_internal_document("Credit Note", "Received", einv, com_id) do
    doc =
      get_internal_doc_query(
        DebitNote,
        einv["uuid"],
        :e_inv_internal_id,
        einv["internalId"],
        com_id
      )

    {doc,
     get_internal_doc_url(
       "DebitNote",
       doc,
       set_dir_main_name(einv, "Received", einv["supplierName"]),
       com_id
     )}
  end

  def get_internal_document("Credit Note", "Sent", einv, com_id) do
    doc =
      get_internal_doc_query(CreditNote, einv["uuid"], :note_no, einv["internalId"], com_id)

    {doc,
     get_internal_doc_url(
       "CreditNote",
       doc,
       set_dir_main_name(einv, "Sent", einv["buyerName"]),
       com_id
     )}
  end

  def get_internal_document("Debit Note", "Received", einv, com_id) do
    doc =
      get_internal_doc_query(
        CreditNote,
        einv["uuid"],
        :e_inv_internal_id,
        einv["internalId"],
        com_id
      )

    {doc,
     get_internal_doc_url(
       "CreditNote",
       doc,
       set_dir_main_name(einv, "Received", einv["supplierName"]),
       com_id
     )}
  end

  def get_internal_document("Debit Note", "Sent", einv, com_id) do
    doc =
      get_internal_doc_query(DebitNote, einv["uuid"], :note_no, einv["internalId"], com_id)

    {doc,
     get_internal_doc_url(
       "DebitNote",
       doc,
       set_dir_main_name(einv, "Sent", einv["buyerName"]),
       com_id
     )}
  end

  def get_internal_document("Refund Note", "Received", einv, com_id) do
    doc =
      get_internal_doc_query(
        Receipt,
        einv["uuid"],
        :e_inv_internal_id,
        einv["internalId"],
        com_id
      )

    {doc,
     get_internal_doc_url(
       "Receipt",
       doc,
       set_dir_main_name(einv, "Received", einv["supplierName"]),
       com_id
     )}
  end

  def get_internal_document("Refund Note", "Sent", einv, com_id) do
    doc =
      get_internal_doc_query(Payment, einv["uuid"], :payment_no, einv["internalId"], com_id)

    {doc,
     get_internal_doc_url(
       "Payment",
       doc,
       set_dir_main_name(einv, "Sent", einv["buyerName"]),
       com_id
     )}
  end

  def get_internal_document("Self-billed Invoice", "Received", einv, com_id) do
    doc =
      get_internal_doc_query(
        Invoice,
        einv["uuid"],
        :e_inv_internal_id,
        einv["internalId"],
        com_id
      )

    {doc,
     get_internal_doc_url(
       "Invoice",
       doc,
       set_dir_main_name(einv, "Received", einv["buyerName"]),
       com_id
     )}
  end

  def get_internal_document("Self-billed Invoice", "Sent", einv, com_id) do
    doc =
      get_internal_doc_query(
        PurInvoice,
        einv["uuid"],
        :e_inv_internal_id,
        einv["internalId"],
        com_id
      )

    {doc,
     get_internal_doc_url(
       "PurInvoice",
       doc,
       set_dir_main_name(einv, "Sent", einv["supplierName"]),
       com_id
     )}
  end

  def get_internal_document("Self-billed Credit Note", "Received", einv, com_id) do
    doc =
      get_internal_doc_query(
        CreditNote,
        einv["uuid"],
        :e_inv_internal_id,
        einv["internalId"],
        com_id
      )

    {doc,
     get_internal_doc_url(
       "CreditNote",
       doc,
       set_dir_main_name(einv, "Received", einv["buyerName"]),
       com_id
     )}
  end

  def get_internal_document("Self-billed Credit Note", "Sent", einv, com_id) do
    doc =
      get_internal_doc_query(DebitNote, einv["uuid"], :note_no, einv["internalId"], com_id)

    {doc,
     get_internal_doc_url(
       "DebitNote",
       doc,
       set_dir_main_name(einv, "Sent", einv["supplierName"]),
       com_id
     )}
  end

  def get_internal_document("Self-billed Debit Note", "Received", einv, com_id) do
    doc =
      get_internal_doc_query(
        DebitNote,
        einv["uuid"],
        :e_inv_internal_id,
        einv["internalId"],
        com_id
      )

    {doc,
     get_internal_doc_url(
       "DebitNote",
       doc,
       set_dir_main_name(einv, "Received", einv["buyerName"]),
       com_id
     )}
  end

  def get_internal_document("Self-billed Debit Note", "Sent", einv, com_id) do
    doc =
      get_internal_doc_query(CreditNote, einv["uuid"], :note_no, einv["internalId"], com_id)

    {doc,
     get_internal_doc_url(
       "CreditNote",
       doc,
       set_dir_main_name(einv, "Sent", einv["supplierName"]),
       com_id
     )}
  end

  def get_internal_document("Self-billed Refund Note", "Received", einv, com_id) do
    doc =
      get_internal_doc_query(
        Payment,
        einv["uuid"],
        :e_inv_internal_id,
        einv["internalId"],
        com_id
      )

    {doc,
     get_internal_doc_url(
       "Payment",
       doc,
       set_dir_main_name(einv, "Received", einv["buyerName"]),
       com_id
     )}
  end

  def get_internal_document("Self-billed Refund Note", "Sent", einv, com_id) do
    doc =
      get_internal_doc_query(Receipt, einv["uuid"], :receipt_no, einv["internalId"], com_id)

    {doc,
     get_internal_doc_url(
       "Receipt",
       doc,
       set_dir_main_name(einv, "Sent", einv["supplierName"]),
       com_id
     )}
  end

  defp get_internal_doc_query(klass, uuid, iid_field, iid, com_id) do
    from(inv in klass,
      where: inv.e_inv_uuid == ^uuid,
      or_where: ^dynamic([inv], fragment("? = ?", field(inv, ^iid_field), ^iid)),
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

  def get_e_invoices(direction, sd, ed, per_page, page, com_id, user_id) do
    meta = get_by_company_id!(com_id, user_id)

    url =
      build_e_inv_url(meta.e_inv_idsrvbaseurl, meta.search_url, [],
        pageSize: per_page,
        issueDateFrom: sd,
        issueDateTo: ed,
        invoiceDirection: direction,
        pageNo: page
      )

    %{"metadata" => _, "result" => res} = Req.get!(url, headers: [Authorization: meta.token]).body

    Enum.map(res, fn x -> Map.merge(x, %{"direction" => direction}) end)
  end

  def get_e_invoices(direction, sd, ed, com_id, user_id) do
    meta = get_by_company_id!(com_id, user_id)

    url =
      build_e_inv_url(meta.e_inv_idsrvbaseurl, meta.search_url, [],
        issueDateFrom: sd,
        issueDateTo: ed,
        invoiceDirection: direction
      )

    %{"metadata" => _, "result" => res} = Req.get!(url, headers: [Authorization: meta.token]).body

    Enum.map(res, fn x -> Map.merge(x, %{"direction" => direction}) end)
  end

  defp refresh_e_invoice_token(meta) do
    url = build_e_inv_url(meta.e_inv_idsrvbaseurl, meta.login_url)

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

  defp set_dir_main_name(einv, dir, name) do
    Map.merge(einv, %{fc_direction: dir, fc_mainName: name})
  end

  def match_fc_doc_to_e_inv(doc_klass, doc, e_inv) do
  end

  def unmatch_fc_doc_to_e_inv(doc_klass, doc, e_inv) do
  end
end
