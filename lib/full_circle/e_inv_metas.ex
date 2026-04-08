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
  alias Phoenix.PubSub
  alias Ecto.Multi

  @default_unit_codes %{
    "-" => "C62",
    "pcs" => "C62", "Pcs" => "C62", "unit" => "C62", "Unit" => "C62", "Chic" => "C62",
    "kg" => "KGM", "Kg" => "KGM", "KG" => "KGM", "Kgs" => "KGM", "g" => "GRM",
    "mt" => "TNE", "Mt" => "TNE",
    "L" => "LTR", "lit" => "LTR", "LIT" => "LTR", "Liter" => "LTR", "Little" => "LTR",
    "ml" => "MLT", "Ml" => "MLT", "ML" => "MLT",
    "bot" => "C62", "Bot" => "C62", "Bots" => "C62", "bottle" => "C62", "btl" => "C62",
    "box" => "C62", "Bag" => "C62", "Bundle" => "C62", "Drum" => "C62", "Tin" => "C62",
    "pkts" => "C62", "VIAL" => "C62",
    "Dose" => "C62", "Doses" => "C62", "DS" => "C62",
    "kWh" => "KWH"
  }

  def default_unit_codes, do: @default_unit_codes

  # Helper to get active environment config from meta
  defp env_config(meta) do
    case meta.environment do
      "sandbox" -> meta.sandbox || %{}
      _ -> meta.production || %{}
    end
  end

  defp api_base(meta), do: env_config(meta)["api_base"] || ""
  defp id_base(meta), do: env_config(meta)["id_base"] || ""
  defp client_id(meta), do: env_config(meta)["client_id"] || ""
  defp client_secret(meta), do: env_config(meta)["client_secret1"] || ""
  defp path(meta, key), do: (meta.paths || %{})[key] || ""

  def portal_base_url(nil), do: "https://myinvois.hasil.gov.my"

  def portal_base_url(%{environment: env, paths: paths}) do
    paths = paths || %{}

    case env do
      "sandbox" -> paths["sandbox_portal"] || "https://preprod.myinvois.hasil.gov.my"
      _ -> paths["portal"] || "https://myinvois.hasil.gov.my"
    end
  end

  def portal_base_url(com, user) do
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

    portal_base_url(meta)
  end

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

  defp get_internal_doc_by_uuid(klass, einv, netamt, payamt, com) do
    from(inv in klass,
      join: txn in Transaction,
      on: txn.doc_id == inv.id,
      join: cont in Contact,
      on: inv.contact_id == cont.id and txn.company_id == ^com.id,
      where: inv.e_inv_uuid == ^einv.uuid,
      where:
        fragment(
          "(round(?, 2) between round(abs(?), 2)-0.02 and round(abs(?), 2)+0.02) or (round(?, 2) between round(abs(?), 2)-0.02 and round(abs(?), 2)+0.02)",
          ^netamt,
          txn.amount,
          txn.amount,
          ^payamt,
          txn.amount,
          txn.amount
        ),
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

  defp get_internal_doc_by_doc_no(klass, field, einv, netamt, payamt, com) do
    from(inv in klass,
      join: txn in Transaction,
      on: txn.doc_id == inv.id,
      join: cont in Contact,
      on: inv.contact_id == cont.id and txn.company_id == ^com.id,
      where: field(inv, ^field) == ^einv.internalId,
      where: is_nil(inv.e_inv_uuid),
      where:
        fragment(
          "(round(?, 2) between round(abs(?), 2)-0.02 and round(abs(?), 2)+0.02) or (round(?, 2) between round(abs(?), 2)-0.02 and round(abs(?), 2)+0.02)",
          ^netamt,
          txn.amount,
          txn.amount,
          ^payamt,
          txn.amount,
          txn.amount
        ),
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
         netamt,
         payamt,
         com
       ) do
    buy_name =
      String.replace(Map.get(einv, :buyerName), ~r/[^a-zA-Z]/, "")
      |> String.slice(0..15)
      |> String.downcase()

    supp_name =
      String.replace(Map.get(einv, :supplierName), ~r/[^a-zA-Z]/, "")
      |> String.slice(0..15)
      |> String.downcase()

    buy_name = "%#{buy_name}%"
    supp_name = "%#{supp_name}%"

    sd = einv.dateTimeReceived |> DateTime.to_date() |> Date.shift(day: -30)
    ed = einv.dateTimeReceived |> DateTime.to_date() |> Date.shift(day: 30)

    from(inv in klass,
      join: txn in Transaction,
      on: txn.doc_id == inv.id,
      join: cont in Contact,
      on: inv.contact_id == cont.id and txn.company_id == ^com.id,
      where:
        fragment(
          "(round(?, 2) between round(abs(?), 2)-0.02 and round(abs(?), 2)+0.02) or (round(?, 2) between round(abs(?), 2)-0.02 and round(abs(?), 2)+0.02)",
          ^netamt,
          txn.amount,
          txn.amount,
          ^payamt,
          txn.amount,
          txn.amount
        ),
      where:
        ilike(
          fragment(
            "lower(left(regexp_replace(?, '[^a-zA-Z]', '', 'g'), 16))",
            cont.name
          ),
          ^supp_name
        ) or
          ilike(
            fragment(
              "lower(left(regexp_replace(?, '[^a-zA-Z]', '', 'g'), 16))",
              cont.name
            ),
            ^buy_name
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

  defp get_fc_doc(klass, einv, doc_no_field, com) do
    q1 = get_internal_doc_by_uuid(klass, einv, einv.totalNetAmount, einv.totalPayableAmount, com)

    q2 =
      get_internal_doc_by_doc_no(
        klass,
        doc_no_field,
        einv,
        einv.totalNetAmount,
        einv.totalPayableAmount,
        com
      )

    q3 =
      get_internal_doc_by_contact(klass, einv, einv.totalNetAmount, einv.totalPayableAmount, com)

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
    get_fc_doc(Invoice, einv, :invoice_no, com) ||
      get_fc_doc(Receipt, einv, :receipt_no, com) || []
  end

  def get_internal_document("Self-billed Invoice", "Sent", einv, com) do
    get_fc_doc(PurInvoice, einv, :e_inv_internal_id, com) ||
      get_fc_doc(Payment, einv, :payment_no, com) || []
  end

  def get_internal_document("Invoice", "Received", einv, com) do
    get_fc_doc(PurInvoice, einv, :e_inv_internal_id, com) ||
      get_fc_doc(Payment, einv, :payment_no, com) || []
  end

  def get_internal_document("Self-billed Invoice", "Received", einv, com) do
    get_fc_doc(Invoice, einv, :invoice_no, com) ||
      get_fc_doc(Receipt, einv, :receipt_no, com) || []
  end

  def get_internal_document("Self-billed Debit Note", "Received", einv, com) do
    get_fc_doc(CreditNote, einv, :note_no, com) || []
  end

  def get_internal_document("Self-billed Debit Note", "Sent", einv, com) do
    get_fc_doc(DebitNote, einv, :note_no, com) || []
  end

  def get_internal_document("Self-billed Credit Note", "Received", einv, com) do
    get_fc_doc(DebitNote, einv, :note_no, com) || []
  end

  def get_internal_document("Self-billed Credit Note", "Sent", einv, com) do
    get_fc_doc(CreditNote, einv, :note_no, com) || []
  end

  def get_internal_document("Credit Note", "Sent", einv, com) do
    get_fc_doc(CreditNote, einv, :note_no, com) || []
  end

  def get_internal_document("Debit Note", "Sent", einv, com) do
    get_fc_doc(DebitNote, einv, :note_no, com) || []
  end

  def get_internal_document("Credit Note", "Received", einv, com) do
    get_fc_doc(DebitNote, einv, :note_no, com) || []
  end

  def get_internal_document("Debit Note", "Received", einv, com) do
    get_fc_doc(CreditNote, einv, :note_no, com) || []
  end

  def get_full_e_invoice(uuid, com, user) do
    meta = get_by_company_id!(com, user)

    if is_nil(meta) do
      {:error, "E-Invoice meta not configured"}
    else
      url =
        build_e_inv_url(api_base(meta), path(meta, "get_doc"), documentUUID: uuid)

      case Req.get(url, headers: [Authorization: meta.token]) do
        {:ok, %{status: 200, body: body}} ->
          {:ok, body}

        {:ok, %{status: status, body: body}} ->
          {:error, "LHDN API returned status #{status}: #{inspect(body)}"}

        {:error, reason} ->
          {:error, "LHDN API request failed: #{inspect(reason)}"}
      end
    end
  end

  def parse_e_invoice_document(body) do
    raw = body["document"]

    invoice =
      if String.starts_with?(String.trim(raw), "<") do
        parse_xml_invoice(raw)
      else
        parse_json_invoice(raw)
      end

    internal_id =
      if invoice[:internal_id] in [nil, ""],
        do: body["internalId"],
        else: invoice[:internal_id]

    Map.merge(invoice, %{
      internal_id: internal_id,
      uuid: body["uuid"],
      total_excluding_tax: parse_number(body["totalExcludingTax"]),
      total_net_amount: parse_number(body["totalNetAmount"]),
      total_payable_amount: parse_number(body["totalPayableAmount"]),
      total_discount: parse_number(body["totalDiscount"])
    })
  end

  defp parse_json_invoice(raw) do
    doc = Jason.decode!(raw)
    invoice = doc["Invoice"] |> List.first()

    supplier =
      invoice["AccountingSupplierParty"]
      |> List.first()
      |> get_in(["Party", Access.at(0)])

    supplier_name =
      get_in(supplier, ["PartyLegalEntity", Access.at(0), "RegistrationName", Access.at(0), "_"])

    supplier_ids = get_in(supplier, ["PartyIdentification"]) || []

    supplier_tin = find_party_id(supplier_ids, "TIN")
    supplier_brn = find_party_id(supplier_ids, "BRN")

    internal_id = get_in(invoice, ["ID", Access.at(0), "_"])
    issue_date = get_in(invoice, ["IssueDate", Access.at(0), "_"])
    currency = get_in(invoice, ["DocumentCurrencyCode", Access.at(0), "_"]) || "MYR"

    type_code =
      get_in(invoice, ["InvoiceTypeCode", Access.at(0), "_"]) ||
        get_in(invoice, ["InvoiceTypeCode", Access.at(0)]) || ""

    invoice_lines =
      (invoice["InvoiceLine"] || [])
      |> Enum.with_index()
      |> Enum.map(fn {line, idx} ->
        %{
          _persistent_id: idx,
          descriptions:
            get_in(line, ["Item", Access.at(0), "Description", Access.at(0), "_"]) || "",
          quantity:
            (get_in(line, ["InvoicedQuantity", Access.at(0), "_"]) || 1.0) |> parse_number(),
          unit: get_in(line, ["InvoicedQuantity", Access.at(0), "unitCode"]) || "",
          unit_price:
            (get_in(line, ["Price", Access.at(0), "PriceAmount", Access.at(0), "_"]) || 0.0)
            |> parse_number(),
          discount: 0,
          tax_rate:
            (get_in(line, [
               "TaxTotal",
               Access.at(0),
               "TaxSubtotal",
               Access.at(0),
               "TaxCategory",
               Access.at(0),
               "Percent",
               Access.at(0),
               "_"
             ]) || 0.0)
            |> parse_number(),
          tax_scheme:
            get_in(line, [
              "TaxTotal",
              Access.at(0),
              "TaxSubtotal",
              Access.at(0),
              "TaxCategory",
              Access.at(0),
              "TaxScheme",
              Access.at(0),
              "ID",
              Access.at(0),
              "_"
            ]),
          tax_code_id_lhdn:
            get_in(line, [
              "TaxTotal",
              Access.at(0),
              "TaxSubtotal",
              Access.at(0),
              "TaxCategory",
              Access.at(0),
              "ID",
              Access.at(0),
              "_"
            ])
        }
      end)

    %{
      internal_id: internal_id,
      issue_date: issue_date,
      currency: currency,
      type_code: type_code,
      supplier_name: supplier_name,
      supplier_tin: supplier_tin,
      supplier_brn: supplier_brn,
      invoice_lines: invoice_lines
    }
  end

  defp find_party_id(ids, scheme) do
    Enum.find_value(ids, fn id ->
      if get_in(id, ["ID", Access.at(0), "schemeID"]) == scheme,
        do: get_in(id, ["ID", Access.at(0), "_"])
    end)
  end

  defp parse_xml_invoice(raw) do
    # Force valid UTF-8 by replacing invalid bytes, then strip namespace prefixes
    clean =
      raw
      |> :unicode.characters_to_binary(:utf8, :utf8)
      |> case do
        {:error, valid, _} -> valid
        {:incomplete, valid, _} -> valid
        bin when is_binary(bin) -> bin
      end

    clean =
      Regex.replace(~r/<\/?[a-z][a-z0-9]*:/, clean, fn m ->
        if String.starts_with?(m, "</"), do: "</", else: "<"
      end)

    internal_id = xml_tag_text(clean, ~r/Invoice>.*?<ID>(.+?)<\/ID>/s)
    issue_date = xml_tag_text(clean, ~r/<IssueDate>(.+?)<\/IssueDate>/s)
    currency = xml_tag_text(clean, ~r/<DocumentCurrencyCode>(.+?)<\/DocumentCurrencyCode>/s)
    currency = if currency == "", do: "MYR", else: currency
    type_code = xml_tag_text(clean, ~r/<InvoiceTypeCode[^>]*>(.+?)<\/InvoiceTypeCode>/s)

    supplier_block = xml_block(clean, "AccountingSupplierParty")

    supplier_name = xml_tag_text(supplier_block, ~r/<RegistrationName>(.+?)<\/RegistrationName>/s)
    supplier_tin = xml_id_by_scheme(supplier_block, "TIN")
    supplier_brn = xml_id_by_scheme(supplier_block, "BRN")

    line_blocks = Regex.scan(~r/<InvoiceLine>(.+?)<\/InvoiceLine>/s, clean)

    invoice_lines =
      line_blocks
      |> Enum.with_index()
      |> Enum.map(fn {[_full, line], idx} ->
        %{
          _persistent_id: idx,
          descriptions: xml_tag_text(line, ~r/<Description>(.+?)<\/Description>/s),
          quantity:
            xml_tag_text(line, ~r/<InvoicedQuantity[^>]*>(.+?)<\/InvoicedQuantity>/s)
            |> parse_number(),
          unit_price:
            xml_tag_text(line, ~r/<PriceAmount[^>]*>(.+?)<\/PriceAmount>/s) |> parse_number(),
          discount: 0,
          tax_rate: xml_tag_text(line, ~r/<Percent>(.+?)<\/Percent>/s) |> parse_number(),
          tax_scheme:
            xml_tag_text(line, ~r/<TaxScheme>\s*<ID[^>]*>(.+?)<\/ID>\s*<\/TaxScheme>/s),
          tax_code_id_lhdn:
            xml_tag_text(line, ~r/<TaxCategory>\s*<ID[^>]*>(.+?)<\/ID>/s),
          unit: xml_tag_text(line, ~r/<InvoicedQuantity[^>]*\bunitCode="([^"]+)"/)
        }
      end)

    %{
      internal_id: internal_id,
      issue_date: issue_date,
      currency: currency,
      type_code: type_code,
      supplier_name: supplier_name,
      supplier_tin: supplier_tin,
      supplier_brn: supplier_brn,
      invoice_lines: invoice_lines
    }
  end

  defp xml_tag_text(xml, regex) do
    case Regex.run(regex, xml) do
      [_, value] -> String.trim(value)
      _ -> ""
    end
  end

  defp xml_block(xml, tag) do
    case Regex.run(~r/<#{tag}>(.*?)<\/#{tag}>/s, xml) do
      [_, block] -> block
      _ -> ""
    end
  end

  defp xml_id_by_scheme(xml, scheme) do
    case Regex.run(~r/<ID[^>]*schemeID="#{scheme}"[^>]*>(.+?)<\/ID>/s, xml) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end

  defp parse_number(""), do: 0.0
  defp parse_number(nil), do: 0.0

  defp parse_number(str) when is_binary(str) do
    case Float.parse(str) do
      {num, _} -> num
      :error -> 0.0
    end
  end

  defp parse_number(num), do: num

  def preview_e_invoice(invoice_id, com, user) do
    invoice = load_invoice_for_submission(invoice_id, com, user)

    if is_nil(invoice) do
      {:error, "Invoice not found"}
    else
      com = Repo.get!(Company, com.id)
      meta = get_by_company_id!(com, user)
      unit_map = if meta, do: Map.merge(@default_unit_codes, meta.unit_code_map || %{}), else: @default_unit_codes
      contact = invoice.contact

      lines =
        invoice.invoice_details
        |> Enum.with_index(1)
        |> Enum.map(fn {d, idx} ->
          {tax_type, tax_scheme} = tax_code_to_lhdn(d.tax_code_name, d.tax_rate)

          %{
            idx: idx,
            description: Enum.join([d.good_name, d.descriptions] |> Enum.reject(&is_nil/1), " - "),
            quantity: Number.Delimit.number_to_delimited(d.quantity),
            unit: d.unit,
            lhdn_unit: to_lhdn_unit(d.unit, unit_map),
            unit_price: Number.Delimit.number_to_delimited(d.unit_price, precision: 4),
            discount: Number.Delimit.number_to_delimited(Decimal.abs(d.discount)),
            good_amount: Number.Delimit.number_to_delimited(d.good_amount),
            tax_rate: Number.Delimit.number_to_delimited(Decimal.mult(d.tax_rate, 100)),
            tax_amount: Number.Delimit.number_to_delimited(d.tax_amount),
            tax_type: "#{tax_type} (#{tax_scheme})"
          }
        end)

      total_tax =
        Enum.reduce(invoice.invoice_details, Decimal.new(0), fn d, acc ->
          Decimal.add(acc, d.tax_amount)
        end)

      total_excl =
        Enum.reduce(invoice.invoice_details, Decimal.new(0), fn d, acc ->
          Decimal.add(acc, d.good_amount)
        end)

      warnings =
        []
        |> validate_field(com.tax_id, "Supplier TIN")
        |> validate_field(com.reg_no, "Supplier BRN")
        |> validate_phone(com.tel, "Supplier Phone")
        |> validate_email(com.email, "Supplier Email")
        |> validate_msic(com.misc_code, "Supplier MSIC")
        |> validate_field(com.address1, "Supplier Address")
        |> validate_field(com.city, "Supplier City")
        |> validate_field(com.zipcode, "Supplier Postal Code")
        |> validate_field(com.state, "Supplier State")
        |> validate_field(contact.tax_id, "Customer TIN")
        |> validate_field(contact.reg_no, "Customer BRN")
        |> validate_phone(contact.contact_info, "Customer Phone")
        |> validate_email(contact.email, "Customer Email")
        |> validate_field(contact.address1, "Customer Address")
        |> validate_field(contact.city, "Customer City")
        |> validate_field(contact.zipcode, "Customer Postal Code")
        |> validate_field(contact.state, "Customer State")
        |> validate_unit_codes(invoice.invoice_details, unit_map)
        |> Enum.reverse()

      {:ok,
       %{
         invoice_no: invoice.invoice_no,
         invoice_date: Date.to_iso8601(invoice.invoice_date),
         supplier: %{
           name: com.name,
           tin: com.tax_id || "N/A",
           brn: com.reg_no || "N/A",
           sst: com.sst_id || "N/A",
           msic: com.misc_code || "N/A",
           tel: com.tel || "N/A",
           email: com.email || "N/A",
           address: com.address1 || "",
           city: com.city || "",
           zipcode: com.zipcode || "",
           state: com.state || ""
         },
         customer: %{
           name: contact.name,
           tin: contact.tax_id || "N/A",
           brn: contact.reg_no || "N/A",
           sst: contact.sst_id || "N/A",
           tel: contact.contact_info || "N/A",
           email: contact.email || "N/A",
           address: contact.address1 || "",
           city: contact.city || "",
           zipcode: contact.zipcode || "",
           state: contact.state || ""
         },
         lines: lines,
         warnings: warnings,
         total_excl: Number.Delimit.number_to_delimited(total_excl),
         total_tax: Number.Delimit.number_to_delimited(total_tax),
         total_incl: Number.Delimit.number_to_delimited(invoice.invoice_amount)
       }}
    end
  end

  def validate_preview(supplier, customer) do
    []
    |> validate_field(supplier[:tin] || supplier.tin, "Supplier TIN")
    |> validate_field(supplier[:brn] || supplier.brn, "Supplier BRN")
    |> validate_phone(supplier[:tel] || supplier.tel, "Supplier Phone")
    |> validate_email(supplier[:email] || supplier.email, "Supplier Email")
    |> validate_msic(supplier[:msic] || supplier.msic, "Supplier MSIC")
    |> validate_field(supplier[:address] || supplier.address, "Supplier Address")
    |> validate_field(supplier[:city] || supplier.city, "Supplier City")
    |> validate_field(supplier[:zipcode] || supplier.zipcode, "Supplier Postal Code")
    |> validate_field(supplier[:state] || supplier.state, "Supplier State")
    |> validate_field(customer[:tin] || customer.tin, "Customer TIN")
    |> validate_field(customer[:brn] || customer.brn, "Customer BRN")
    |> validate_phone(customer[:tel] || customer.tel, "Customer Phone")
    |> validate_email(customer[:email] || customer.email, "Customer Email")
    |> validate_field(customer[:address] || customer.address, "Customer Address")
    |> validate_field(customer[:city] || customer.city, "Customer City")
    |> validate_field(customer[:zipcode] || customer.zipcode, "Customer Postal Code")
    |> validate_field(customer[:state] || customer.state, "Customer State")
    |> Enum.reverse()
  end

  def submit_e_invoice(invoice_id, preview, com, user) do
    meta = get_by_company_id!(com, user)

    if is_nil(meta) do
      {:error, "E-Invoice meta not configured"}
    else
      invoice = load_invoice_for_submission(invoice_id, com, user)

      if is_nil(invoice) do
        {:error, "Invoice not found"}
      else
        if invoice.e_inv_uuid do
          {:error, "Invoice already submitted (UUID: #{invoice.e_inv_uuid})"}
        else
          do_submit_e_invoice(meta, invoice, preview, com, user)
        end
      end
    end
  end

  defp do_submit_e_invoice(meta, invoice, preview, com, user) do
    com = Repo.get!(Company, com.id)
    unit_map = Map.merge(@default_unit_codes, meta.unit_code_map || %{})
    ubl_json = build_invoice_ubl(invoice, com, preview, unit_map)
    encoded = Jason.encode!(ubl_json)
    require Logger
    Logger.info("E-Invoice UBL JSON: #{encoded}")
    doc_base64 = Base.encode64(encoded)
    doc_hash = :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)

    submit_body = %{
      "documents" => [
        %{
          "format" => "JSON",
          "document" => doc_base64,
          "documentHash" => doc_hash,
          "codeNumber" => invoice.invoice_no
        }
      ]
    }

    url = build_e_inv_url(api_base(meta), path(meta, "submit"))

    case Req.post(url,
           json: submit_body,
           headers: [Authorization: meta.token, "Content-Type": "application/json"]
         ) do
      {:ok, %{status: status, body: body}} when status in [200, 202] ->
        handle_submission_response(body, invoice, com, user)

      {:ok, %{status: status, body: body}} ->
        {:error, "LHDN returned status #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "LHDN request failed: #{inspect(reason)}"}
    end
  end

  defp handle_submission_response(body, invoice, com, user) do
    accepted = body["acceptedDocuments"] || []
    rejected = body["rejectedDocuments"] || []

    cond do
      length(accepted) > 0 ->
        doc = List.first(accepted)
        uuid = doc["uuid"]
        internal_id = doc["invoiceCodeNumber"] || invoice.invoice_no

        Multi.new()
        |> Multi.update_all(
          :update_invoice,
          from(inv in Invoice,
            where: inv.id == ^invoice.id,
            update: [set: [e_inv_uuid: ^uuid, e_inv_internal_id: ^internal_id]]
          ),
          []
        )
        |> Multi.insert(:logging, %Log{
          entity: "invoices",
          entity_id: invoice.id,
          action: "update",
          delta: "Note: Submitted to LHDN e-Invoice, UUID: #{uuid}",
          user_id: user.id,
          company_id: com.id
        })
        |> Repo.transaction()

        {:ok, uuid}

      length(rejected) > 0 ->
        doc = List.first(rejected)
        error = doc["error"] || doc
        {:error, "LHDN rejected: #{inspect(error)}"}

      true ->
        {:error, "Unexpected response: no accepted or rejected documents"}
    end
  end

  defp load_invoice_for_submission(invoice_id, com, user) do
    alias FullCircle.Billing.InvoiceDetail
    alias FullCircle.Accounting.{Account, TaxCode}
    alias FullCircle.Product.{Good, Packaging}
    alias FullCircle.Sys

    detail_query =
      from invd in InvoiceDetail,
        join: good in Good,
        on: good.id == invd.good_id,
        join: ac in Account,
        on: invd.account_id == ac.id,
        join: tc in TaxCode,
        on: tc.id == invd.tax_code_id,
        left_join: pkg in Packaging,
        on: pkg.id == invd.package_id,
        order_by: invd._persistent_id,
        select: invd,
        select_merge: %{
          good_name: good.name,
          account_name: ac.name,
          unit: good.unit,
          tax_code_name: tc.code,
          tax_rate: invd.tax_rate,
          unit_multiplier: pkg.unit_multiplier,
          package_name: pkg.name,
          tax_amount:
            fragment(
              "round(?, 2)",
              (invd.quantity * invd.unit_price + invd.discount) * invd.tax_rate
            ),
          good_amount:
            fragment(
              "round(?, 2)",
              invd.quantity * invd.unit_price + invd.discount
            ),
          amount:
            fragment(
              "round(?, 2)",
              invd.quantity * invd.unit_price + invd.discount +
                (invd.quantity * invd.unit_price + invd.discount) * invd.tax_rate
            )
        }

    Repo.one(
      from inv in Invoice,
        join: com_q in subquery(Sys.user_company(com, user)),
        on: com_q.id == inv.company_id,
        join: cont in Contact,
        on: cont.id == inv.contact_id,
        where: inv.id == ^invoice_id,
        preload: [contact: cont, invoice_details: ^detail_query],
        select: inv,
        select_merge: %{
          contact_name: cont.name,
          contact_id: cont.id,
          reg_no: cont.reg_no,
          tax_id: cont.tax_id
        }
    )
    |> case do
      nil -> nil
      inv -> Invoice.compute_struct_fields(inv)
    end
  end

  defp build_invoice_ubl(invoice, com, preview, unit_map) do
    sup = preview.supplier
    cust = preview.customer
    issue_date = Date.to_iso8601(invoice.invoice_date)
    issue_time = "00:00:00Z"

    tax_subtotals = build_tax_subtotals(invoice.invoice_details)

    total_tax =
      Enum.reduce(invoice.invoice_details, Decimal.new(0), fn d, acc ->
        Decimal.add(acc, d.tax_amount)
      end)
      |> Decimal.to_float()

    total_excl =
      Enum.reduce(invoice.invoice_details, Decimal.new(0), fn d, acc ->
        Decimal.add(acc, d.good_amount)
      end)
      |> Decimal.to_float()

    total_incl = Decimal.to_float(invoice.invoice_amount)

    total_discount =
      Enum.reduce(invoice.invoice_details, Decimal.new(0), fn d, acc ->
        Decimal.add(acc, Decimal.abs(d.discount))
      end)
      |> Decimal.to_float()

    %{
      "_D" => "urn:oasis:names:specification:ubl:schema:xsd:Invoice-2",
      "_A" => "urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2",
      "_B" => "urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2",
      "Invoice" => [
        %{
          "ID" => [%{"_" => invoice.invoice_no}],
          "IssueDate" => [%{"_" => issue_date}],
          "IssueTime" => [%{"_" => issue_time}],
          "InvoiceTypeCode" => [%{"_" => "01", "listVersionID" => "1.0"}],
          "DocumentCurrencyCode" => [%{"_" => "MYR"}],
          "InvoicePeriod" => [
            %{
              "StartDate" => [%{"_" => issue_date}],
              "EndDate" => [%{"_" => issue_date}],
              "Description" => [%{"_" => "Monthly"}]
            }
          ],
          "AccountingSupplierParty" => [
            %{
              "Party" => [
                build_party(
                  sup.name,
                  sup.tin,
                  sup.brn,
                  sup.sst,
                  com.tou_id,
                  sup.address,
                  sup.city,
                  sup.zipcode,
                  sup.state,
                  sup.tel,
                  sup.email,
                  sup.msic
                )
              ]
            }
          ],
          "AccountingCustomerParty" => [
            %{
              "Party" => [
                build_party(
                  cust.name,
                  cust.tin,
                  cust.brn,
                  cust.sst,
                  nil,
                  cust.address,
                  cust.city,
                  cust.zipcode,
                  cust.state,
                  cust.tel,
                  cust.email,
                  nil
                )
              ]
            }
          ],
          "TaxTotal" => [
            %{
              "TaxAmount" => [%{"_" => total_tax, "currencyID" => "MYR"}],
              "TaxSubtotal" => tax_subtotals
            }
          ],
          "LegalMonetaryTotal" => [
            %{
              "LineExtensionAmount" => [%{"_" => total_excl, "currencyID" => "MYR"}],
              "TaxExclusiveAmount" => [%{"_" => total_excl, "currencyID" => "MYR"}],
              "TaxInclusiveAmount" => [%{"_" => total_incl, "currencyID" => "MYR"}],
              "AllowanceTotalAmount" => [%{"_" => total_discount, "currencyID" => "MYR"}],
              "PayableAmount" => [%{"_" => total_incl, "currencyID" => "MYR"}]
            }
          ],
          "InvoiceLine" =>
            invoice.invoice_details
            |> Enum.with_index(1)
            |> Enum.map(fn {detail, idx} -> build_invoice_line(detail, idx, unit_map) end)
        }
      ]
    }
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?("N/A"), do: false
  defp present?("NA"), do: false
  defp present?(_), do: true

  defp build_party(name, tin, brn, sst, tou, address, city, zipcode, state, tel, email, msic) do
    # TIN and BRN are always required by LHDN
    ids =
      [
        %{"ID" => [%{"_" => if(present?(tin), do: tin, else: "NA"), "schemeID" => "TIN"}]},
        %{"ID" => [%{"_" => if(present?(brn), do: brn, else: "NA"), "schemeID" => "BRN"}]},
        if(present?(sst), do: %{"ID" => [%{"_" => sst, "schemeID" => "SST"}]}),
        if(present?(tou), do: %{"ID" => [%{"_" => tou, "schemeID" => "TTX"}]})
      ]
      |> Enum.reject(&is_nil/1)

    party = %{
      "PartyLegalEntity" => [%{"RegistrationName" => [%{"_" => name || ""}]}],
      "PartyIdentification" => ids,
      "PostalAddress" => [
        %{
          "AddressLine" => [%{"Line" => [%{"_" => address || "NA"}]}],
          "CityName" => [%{"_" => city || "NA"}],
          "PostalZone" => [%{"_" => zipcode || "NA"}],
          "CountrySubentityCode" => [%{"_" => state_to_code(state)}],
          "Country" => [
            %{
              "IdentificationCode" => [
                %{"_" => "MYS", "listID" => "ISO3166-1", "listAgencyID" => "6"}
              ]
            }
          ]
        }
      ],
      "Contact" => [
        %{
          "Telephone" => [%{"_" => format_phone(tel)}],
          "ElectronicMail" => [%{"_" => email || "NA"}]
        }
      ]
    }

    if msic do
      Map.put(party, "IndustryClassificationCode", [%{"_" => msic, "name" => msic}])
    else
      party
    end
  end

  defp to_lhdn_unit(nil, _map), do: "C62"
  defp to_lhdn_unit(unit, map), do: Map.get(map, unit, "C62")

  defp unit_mapped?(nil, _map), do: true
  defp unit_mapped?(unit, map), do: Map.has_key?(map, unit)

  defp validate_unit_codes(warnings, details, unit_map) do
    details
    |> Enum.reject(fn d -> unit_mapped?(d.unit, unit_map) end)
    |> Enum.map(fn d -> "Unit '#{d.unit}' (#{d.good_name}) not in LHDN unit mapping, defaulting to C62. Add mapping in E-Invoice Meta settings." end)
    |> Enum.uniq()
    |> Enum.reduce(warnings, fn w, acc -> [w | acc] end)
  end

  defp build_invoice_line(detail, idx, unit_map) do
    good_amount = Decimal.to_float(detail.good_amount)
    tax_amount = Decimal.to_float(detail.tax_amount)
    unit_price = Decimal.to_float(detail.unit_price)
    quantity = Decimal.to_float(detail.quantity)
    discount = Decimal.to_float(Decimal.abs(detail.discount))
    tax_rate = Decimal.to_float(Decimal.mult(detail.tax_rate, 100))
    {tax_type, tax_scheme} = tax_code_to_lhdn(detail.tax_code_name, detail.tax_rate)

    line = %{
      "ID" => [%{"_" => "#{idx}"}],
      "InvoicedQuantity" => [%{"_" => quantity, "unitCode" => to_lhdn_unit(detail.unit, unit_map)}],
      "LineExtensionAmount" => [%{"_" => good_amount, "currencyID" => "MYR"}],
      "Item" => [
        %{
          "Description" => [%{"_" => Enum.join([detail.good_name, detail.descriptions] |> Enum.reject(&is_nil/1), " - ")}],
          "CommodityClassification" => [
            %{"ItemClassificationCode" => [%{"_" => "022", "listID" => "CLASS"}]}
          ]
        }
      ],
      "Price" => [%{"PriceAmount" => [%{"_" => unit_price, "currencyID" => "MYR"}]}],
      "ItemPriceExtension" => [
        %{"Amount" => [%{"_" => quantity * unit_price, "currencyID" => "MYR"}]}
      ],
      "TaxTotal" => [
        %{
          "TaxAmount" => [%{"_" => tax_amount, "currencyID" => "MYR"}],
          "TaxSubtotal" => [
            %{
              "TaxableAmount" => [%{"_" => good_amount, "currencyID" => "MYR"}],
              "TaxAmount" => [%{"_" => tax_amount, "currencyID" => "MYR"}],
              "TaxCategory" => [
                %{
                  "ID" => [%{"_" => tax_type}],
                  "Percent" => [%{"_" => tax_rate}],
                  "TaxScheme" => [
                    %{
                      "ID" => [
                        %{
                          "_" => tax_scheme,
                          "schemeID" => "UN/ECE 5153",
                          "schemeAgencyID" => "6"
                        }
                      ]
                    }
                  ]
                }
              ]
            }
          ]
        }
      ]
    }

    if discount > 0 do
      Map.put(line, "AllowanceCharge", [
        %{
          "ChargeIndicator" => [%{"_" => false}],
          "AllowanceChargeReason" => [%{"_" => "Discount"}],
          "Amount" => [%{"_" => discount, "currencyID" => "MYR"}]
        }
      ])
    else
      line
    end
  end

  defp build_tax_subtotals(details) do
    details
    |> Enum.group_by(fn d ->
      {tax_code_to_lhdn(d.tax_code_name, d.tax_rate), d.tax_rate}
    end)
    |> Enum.map(fn {{{tax_type, tax_scheme}, tax_rate}, group} ->
      taxable =
        Enum.reduce(group, Decimal.new(0), fn d, acc -> Decimal.add(acc, d.good_amount) end)
        |> Decimal.to_float()

      tax_amt =
        Enum.reduce(group, Decimal.new(0), fn d, acc -> Decimal.add(acc, d.tax_amount) end)
        |> Decimal.to_float()

      %{
        "TaxableAmount" => [%{"_" => taxable, "currencyID" => "MYR"}],
        "TaxAmount" => [%{"_" => tax_amt, "currencyID" => "MYR"}],
        "TaxCategory" => [
          %{
            "ID" => [%{"_" => tax_type}],
            "Percent" => [%{"_" => Decimal.to_float(Decimal.mult(tax_rate, 100))}],
            "TaxScheme" => [
              %{
                "ID" => [
                  %{
                    "_" => tax_scheme,
                    "schemeID" => "UN/ECE 5153",
                    "schemeAgencyID" => "6"
                  }
                ]
              }
            ]
          }
        ]
      }
    end)
  end

  defp tax_code_to_lhdn(tax_code_name, tax_rate) do
    cond do
      Decimal.eq?(tax_rate, 0) -> {"06", "OTH"}
      String.contains?(tax_code_name || "", "SV") -> {"02", "OTH"}
      true -> {"01", "OTH"}
    end
  end

  @state_codes %{
    "Johor" => "01",
    "Kedah" => "02",
    "Kelantan" => "03",
    "Melaka" => "04",
    "Negeri Sembilan" => "05",
    "Pahang" => "06",
    "Pulau Pinang" => "07",
    "Perak" => "08",
    "Perlis" => "09",
    "Selangor" => "10",
    "Terengganu" => "11",
    "Sabah" => "12",
    "Sarawak" => "13",
    "WP Kuala Lumpur" => "14",
    "WP Labuan" => "15",
    "WP Putrajaya" => "16",
    "Kuala Lumpur" => "14",
    "Labuan" => "15",
    "Putrajaya" => "16"
  }

  defp format_phone(nil), do: "NA"
  defp format_phone(""), do: "NA"

  defp format_phone(phone) do
    clean = String.replace(phone, ~r/[\s\-()]/, "")

    if String.starts_with?(clean, "+") do
      clean
    else
      "+6" <> clean
    end
    |> String.slice(0, 20)
  end

  defp state_to_code(nil), do: "17"

  defp state_to_code(state) do
    Map.get(@state_codes, state, "17")
  end

  defp validate_field(warnings, nil, label), do: ["#{label} is missing" | warnings]
  defp validate_field(warnings, "", label), do: ["#{label} is missing" | warnings]
  defp validate_field(warnings, _, _), do: warnings

  defp validate_phone(warnings, nil, label), do: ["#{label} is missing" | warnings]
  defp validate_phone(warnings, "", label), do: ["#{label} is missing" | warnings]

  defp validate_phone(warnings, phone, label) do
    clean = String.replace(phone, ~r/[\s\-()]/, "")

    cond do
      String.length(clean) > 20 -> ["#{label} exceeds 20 chars" | warnings]
      !Regex.match?(~r/^\+?[0-9]+$/, clean) -> ["#{label} has invalid format (use digits, optional +)" | warnings]
      true -> warnings
    end
  end

  defp validate_email(warnings, nil, label), do: ["#{label} is missing" | warnings]
  defp validate_email(warnings, "", label), do: ["#{label} is missing" | warnings]

  defp validate_email(warnings, email, label) do
    if Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email) do
      warnings
    else
      ["#{label} is invalid (#{email})" | warnings]
    end
  end

  defp validate_msic(warnings, nil, label), do: ["#{label} is missing" | warnings]
  defp validate_msic(warnings, "", label), do: ["#{label} is missing" | warnings]

  defp validate_msic(warnings, msic, label) do
    if Regex.match?(~r/^\d{5}$/, msic) do
      warnings
    else
      ["#{label} must be a 5-digit code (got: #{msic})" | warnings]
    end
  end

  def get_e_invs(uuid, internal_id, contact, amount, doc_date, com, user) do
    q1 = get_e_invoices_by_uuid(uuid, amount, com, user)
    q2 = get_e_invoices_by_internal_id(internal_id, amount, com, user)
    q3 = get_e_invoices_by_contact(contact, amount, doc_date, com, user)

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
      on: c.id == ei.company_id,
      join: cu in CompanyUser,
      on: cu.company_id == c.id,
      where: ei.uuid == ^uuid,
      where: c.id == ^com.id,
      where: cu.user_id == ^user.id,
      distinct: true,
      where:
        fragment(
          "(round(?,2) between round(?,2)-0.02 and round(?,2)+0.02) or (round(?,2) between round(?,2)-0.02 and round(?,2)+0.02)",
          ^amount,
          ei.totalPayableAmount,
          ei.totalPayableAmount,
          ^amount,
          ei.totalNetAmount,
          ei.totalNetAmount
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
        priority: 1
      }
    )
  end

  defp get_e_invoices_by_internal_id(internal_id, amount, com, user) do
    from(ei in EInvoice,
      join: c in Company,
      on: c.id == ei.company_id,
      join: cu in CompanyUser,
      on: cu.company_id == c.id,
      where: ilike(ei.internalId, ^"%#{internal_id}%"),
      where: c.id == ^com.id,
      where: cu.user_id == ^user.id,
      distinct: true,
      where:
        fragment(
          "(round(?,2) between round(?,2)-0.02 and round(?,2)+0.02) or (round(?,2) between round(?,2)-0.02 and round(?,2)+0.02)",
          ^amount,
          ei.totalPayableAmount,
          ei.totalPayableAmount,
          ^amount,
          ei.totalNetAmount,
          ei.totalNetAmount
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
        priority: 2
      }
    )
  end

  defp get_e_invoices_by_contact(contact, amount, doc_date, com, user) do
    clean_contact =
      String.replace(contact, ~r/[^a-zA-Z]/, "")
      |> String.slice(0..15)
      |> String.downcase()

    sd = doc_date |> Timex.to_datetime() |> DateTime.shift(day: -5)
    ed = doc_date |> Timex.to_datetime() |> DateTime.shift(day: 5)

    from(ei in EInvoice,
      join: c in Company,
      on: c.id == ei.company_id,
      join: cu in CompanyUser,
      on: cu.company_id == c.id,
      where: c.id == ^com.id,
      where: cu.user_id == ^user.id,
      where: ei.dateTimeReceived >= ^sd,
      where: ei.dateTimeReceived <= ^ed,
      distinct: true,
      where:
        fragment(
          "(round(?,2) between round(?,2)-0.02 and round(?,2)+0.02) or (round(?,2) between round(?,2)-0.02 and round(?,2)+0.02)",
          ^amount,
          ei.totalPayableAmount,
          ei.totalPayableAmount,
          ^amount,
          ei.totalNetAmount,
          ei.totalNetAmount
        ),
      where:
        ilike(
          fragment(
            "lower(left(regexp_replace(?, '[^a-zA-Z]', '', 'g'), 16))",
            ei.buyerName
          ),
          ^"%#{clean_contact}%"
        ) or
          ilike(
            fragment(
              "lower(left(regexp_replace(?, '[^a-zA-Z]', '', 'g'), 16))",
              ei.supplierName
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
      build_e_inv_url(id_base(meta), path(meta, "search"), [],
        submissionDateFrom: sd,
        submissionDateTo: ed,
        pageSize: 1,
        pageNo: 1
      )

    %{"metadata" => %{"totalCount" => total_count}, "result" => _} =
      Req.get!(meta_url, headers: [Authorization: meta.token]).body

    pages = (total_count / 100) |> Float.ceil() |> trunc()
    pages = if pages == 0, do: 1, else: pages

    Enum.map(1..pages, fn p ->
      url =
        build_e_inv_url(id_base(meta), path(meta, "search"), [],
          submissionDateFrom: sd,
          submissionDateTo: ed,
          pageSize: 100,
          pageNo: p
        )

      PubSub.broadcast(
        FullCircle.PubSub,
        "#{com.id}_e_invoice_sync_status",
        {:update_sync_status, sd, ed, p}
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
    last_sync = e_invoice_last_sync_datetime(com, user) |> DateTime.add(-3, :day)

    now = DateTime.utc_now()
    range = get_date_range(last_sync, now) |> Enum.chunk_every(2, 1, :discard)

    Enum.each(range, fn [a, b] ->
      lt =
        get_e_invoices_from_cloud(
          Timex.format!(a, "%Y-%m-%dT%H:%M:%S", :strftime),
          Timex.format!(b, "%Y-%m-%dT%H:%M:%S", :strftime),
          com,
          user
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

    remove_uuid_from_invalid_e_invoices(last_sync, now, com, user)
  end

  defp get_date_range(a, b) do
    if DateTime.add(a, 60 * 60 * 24 * 5, :second) |> DateTime.compare(b) == :gt do
      [a, DateTime.add(a, Integer.mod(DateTime.diff(b, a), 60 * 60 * 24 * 5), :second)]
    else
      [a, get_date_range(DateTime.add(a, 60 * 60 * 24 * 5, :second), b)] |> List.flatten()
    end
  end

  defp refresh_e_invoice_token(meta) do
    url = build_e_inv_url(id_base(meta), path(meta, "login"))

    try do
      result =
        Req.post!(url,
          form: [
            client_id: client_id(meta),
            client_secret: client_secret(meta),
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

  def remove_uuid_from_invalid_e_invoices(sd, ed, com, user) do
    from(ei in EInvoice,
      join: c in Company,
      on: c.id == ei.company_id,
      join: cu in CompanyUser,
      on: cu.company_id == c.id,
      where: c.id == ^com.id,
      where: cu.user_id == ^user.id,
      where: ei.dateTimeReceived >= ^sd,
      where: ei.dateTimeReceived <= ^ed,
      where: ei.status != "Valid"
    )
    |> Repo.all()
    |> Enum.each(fn x ->
      fc_doc = get_fc_doc_by_uuid(x.uuid, com)

      if fc_doc do
        unmatch(fc_doc, com, user)
      end
    end)
  end

  def get_fc_doc_by_uuid(uuid, com) do
    inv_qry =
      from(obj in Invoice,
        where: obj.company_id == ^com.id,
        where: obj.e_inv_uuid == ^uuid,
        select: %{doc_id: obj.id, doc_type: "Invoice"}
      )

    pur_inv_qry =
      from(obj in PurInvoice,
        where: obj.company_id == ^com.id,
        where: obj.e_inv_uuid == ^uuid,
        select: %{doc_id: obj.id, doc_type: "PurInvoice"}
      )

    pay_qry =
      from(obj in Payment,
        where: obj.company_id == ^com.id,
        where: obj.e_inv_uuid == ^uuid,
        select: %{doc_id: obj.id, doc_type: "Payment"}
      )

    rec_qry =
      from(obj in Receipt,
        where: obj.company_id == ^com.id,
        where: obj.e_inv_uuid == ^uuid,
        select: %{doc_id: obj.id, doc_type: "Receipt"}
      )

    db_note_qry =
      from(obj in DebitNote,
        where: obj.company_id == ^com.id,
        where: obj.e_inv_uuid == ^uuid,
        select: %{doc_id: obj.id, doc_type: "DebitNote"}
      )

    cr_note_qry =
      from(obj in CreditNote,
        where: obj.company_id == ^com.id,
        where: obj.e_inv_uuid == ^uuid,
        select: %{doc_id: obj.id, doc_type: "CreditNote"}
      )

    inv_qry
    |> union(^pur_inv_qry)
    |> union(^pay_qry)
    |> union(^rec_qry)
    |> union(^db_note_qry)
    |> union(^cr_note_qry)
    |> Repo.one()
  end
end
