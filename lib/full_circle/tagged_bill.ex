defmodule FullCircle.TaggedBill do
  import Ecto.Query, warn: false

  alias FullCircle.Repo
  alias FullCircle.Accounting.Contact

  def transport_commission(tags, fdate, tdate, com_id) do
    tag = tags |> String.split(" ", trim: true) |> Enum.at(0)

    # ors =
    #   for t <- tags do
    #     dynamic(
    #       [cont],
    #       fragment(
    #         "? ilike ? or ? ilike ?",
    #         cont.loader_tags,
    #         ^"%#{t}%",
    #         cont.delivery_man_tags,
    #         ^"%#{t}%"
    #       )
    #     )
    #   end
    #   |> Enum.reduce(fn a, b -> dynamic(^a or ^b) end)

    inv_ids_qry =
      from(i in FullCircle.Billing.Invoice,
        # where: ^ors,
        where:
          fragment(
            "? ilike ? or ? ilike ?",
            i.loader_tags,
            ^"%#{tag}%",
            i.delivery_man_tags,
            ^"%#{tag}%"
          ),
        where: i.company_id == ^com_id,
        where: i.invoice_date >= ^fdate,
        where: i.invoice_date <= ^tdate,
        select: i.id
      )

    pur_inv_ids_qry =
      from(i in FullCircle.Billing.PurInvoice,
        # where: ^ors,
        where:
          fragment(
            "? ilike ? or ? ilike ?",
            i.loader_tags,
            ^"%#{tag}%",
            i.delivery_man_tags,
            ^"%#{tag}%"
          ),
        where: i.company_id == ^com_id,
        where: i.pur_invoice_date >= ^fdate,
        where: i.pur_invoice_date <= ^tdate,
        select: i.id
      )

    ids_qry = union_all(inv_ids_qry, ^pur_inv_ids_qry)

    inv =
      from(inv in FullCircle.Billing.Invoice,
        join: invd in FullCircle.Billing.InvoiceDetail,
        on: invd.invoice_id == inv.id,
        join: gd in FullCircle.Product.Good,
        on: gd.id == invd.good_id,
        join: cont in Contact,
        on: cont.id == inv.contact_id,
        where: inv.id in subquery(ids_qry),
        select: %{
          doc_no: inv.invoice_no,
          invoice_date: inv.invoice_date,
          contact: cont.name,
          good_names: fragment("string_agg(distinct ?, ', ')", gd.name),
          quantity: sum(invd.quantity),
          loader_tags: fragment("string_agg(distinct ?, '')", inv.loader_tags),
          delivery_man_tags: fragment("string_agg(distinct ?, '')", inv.delivery_man_tags),
          loader_wages_tags: fragment("string_agg(distinct ?, '')", inv.loader_wages_tags),
          delivery_wages_tags: fragment("string_agg(distinct ?, '')", inv.delivery_wages_tags),
          unit: gd.unit
        },
        group_by: [
          cont.name,
          inv.invoice_no,
          inv.invoice_date,
          gd.unit
        ]
      )

    pur_inv =
      from(inv in FullCircle.Billing.PurInvoice,
        join: invd in FullCircle.Billing.PurInvoiceDetail,
        on: invd.pur_invoice_id == inv.id,
        join: gd in FullCircle.Product.Good,
        on: gd.id == invd.good_id,
        join: cont in Contact,
        on: cont.id == inv.contact_id,
        where: inv.id in subquery(ids_qry),
        select: %{
          doc_no: inv.pur_invoice_no,
          invoice_date: inv.pur_invoice_date,
          contact: cont.name,
          good_names: fragment("string_agg(distinct ?, ', ')", gd.name),
          quantity: sum(invd.quantity),
          loader_tags: fragment("string_agg(distinct ?, '')", inv.loader_tags),
          delivery_man_tags: fragment("string_agg(distinct ?, '')", inv.delivery_man_tags),
          loader_wages_tags: fragment("string_agg(distinct ?, '')", inv.loader_wages_tags),
          delivery_wages_tags: fragment("string_agg(distinct ?, '')", inv.delivery_wages_tags),
          unit: gd.unit
        },
        group_by: [
          cont.name,
          inv.pur_invoice_no,
          inv.pur_invoice_date,
          gd.unit
        ]
      )

    union_all(inv, ^pur_inv)
    |> order_by([2, 3])
    |> Repo.all()
    |> Enum.map(fn x ->
      Map.merge(x, %{
        loader_tags: String.split(x.loader_tags) |> Enum.uniq() |> Enum.join(", "),
        loader_tags_count: String.split(x.loader_tags) |> Enum.uniq() |> Enum.count(),
        delivery_man_tags: String.split(x.delivery_man_tags) |> Enum.uniq() |> Enum.join(", "),
        delivery_man_tags_count: String.split(x.delivery_man_tags) |> Enum.uniq() |> Enum.count()
      })
    end)
    |> Enum.map(fn x ->
      Map.merge(x, %{
        load_wages:
          (wages_parse(x.loader_wages_tags, tag, x.loader_tags) * Decimal.to_float(x.quantity) /
             x.loader_tags_count)
          |> Float.round(2),
        delivery_wages:
          (wages_parse(x.delivery_wages_tags, tag, x.delivery_man_tags) *
             Decimal.to_float(x.quantity) /
             x.delivery_man_tags_count)
          |> Float.round(2)
      })
    end)
  end

  defp wages_parse(tag, emp_tag, data_tags) do
    tag = tag || ""

    {wage, _} =
      (Regex.scan(~r/(?<=\[).+?(?=\])/, tag) |> List.flatten() |> List.first() ||
         "0.0")
      |> Float.parse()

    data_tags = data_tags |> String.split(",") |> Enum.map(fn x -> String.trim(x) end)

    if !is_nil(Enum.find(data_tags, fn x -> x == emp_tag end)) do
      wage
    else
      0.0
    end
  end
end
