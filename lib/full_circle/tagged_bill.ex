defmodule FullCircle.TaggedBill do
  import Ecto.Query, warn: false

  alias FullCircle.Repo
  alias FullCircle.Accounting.Contact

  def goods_sales_report(contact, goods, fdate, tdate, com_id) do
    good_lst = goods |> String.split(",") |> Enum.map(fn x -> String.trim(x) end)
    cont = FullCircle.Accounting.get_contact_by_name(contact, %{id: com_id}, nil)

    goods_qry =
      from(gd in FullCircle.Product.Good,
        where: gd.name in ^good_lst
      )

    inv =
      from(inv in FullCircle.Billing.Invoice,
        join: invd in FullCircle.Billing.InvoiceDetail,
        on: invd.invoice_id == inv.id,
        join: gd in ^goods_qry,
        on: gd.id == invd.good_id,
        join: cont in Contact,
        on: cont.id == inv.contact_id,
        join: pkg in FullCircle.Product.Packaging,
        on: pkg.id == invd.package_id,
        where: inv.invoice_date >= ^fdate,
        where: inv.invoice_date <= ^tdate,
        where: inv.company_id == ^com_id,
        select: %{
          doc_no: inv.invoice_no,
          invoice_date: inv.invoice_date,
          contact: cont.name,
          good: gd.name,
          pack_name: pkg.name,
          pack_qty: invd.package_qty,
          qty: invd.quantity,
          avg_qty:
            fragment(
              "? / case when ? = 0 then 1 else ? end",
              invd.quantity,
              invd.package_qty,
              invd.package_qty
            ),
          unit: gd.unit,
          price: (invd.unit_price * invd.quantity - invd.discount) / invd.quantity,
          amount: invd.unit_price * invd.quantity - invd.discount
        }
      )

    inv = if(cont, do: from(i in inv, where: i.contact_id == ^cont.id), else: inv)

    rec =
      from(inv in FullCircle.ReceiveFund.Receipt,
        join: invd in FullCircle.ReceiveFund.ReceiptDetail,
        on: invd.receipt_id == inv.id,
        join: gd in ^goods_qry,
        on: gd.id == invd.good_id,
        join: cont in Contact,
        on: cont.id == inv.contact_id,
        join: pkg in FullCircle.Product.Packaging,
        on: pkg.id == invd.package_id,
        where: inv.receipt_date >= ^fdate,
        where: inv.receipt_date <= ^tdate,
        where: inv.company_id == ^com_id,
        select: %{
          doc_no: inv.receipt_no,
          doc_date: inv.receipt_date,
          contact: cont.name,
          good: gd.name,
          pack_name: pkg.name,
          pack_qty: invd.package_qty,
          qty: invd.quantity,
          avg_qty:
            fragment(
              "? / case when ? = 0 then 1 else ? end",
              invd.quantity,
              invd.package_qty,
              invd.package_qty
            ),
          unit: gd.unit,
          price: (invd.unit_price * invd.quantity - invd.discount) / invd.quantity,
          amount: invd.unit_price * invd.quantity - invd.discount
        }
      )

    rec = if(cont, do: from(i in rec, where: i.contact_id == ^cont.id), else: rec)

    union_all(rec, ^inv) |> order_by([2, 1, 4]) |> Repo.all()
  end

  def goods_sales_summary_report(contact, goods, fdate, tdate, com_id) do
    good_lst = goods |> String.split(",") |> Enum.map(fn x -> String.trim(x) end)
    cont = FullCircle.Accounting.get_contact_by_name(contact, %{id: com_id}, nil)

    goods_qry =
      from(gd in FullCircle.Product.Good,
        where: gd.name in ^good_lst
      )

    inv =
      from(inv in FullCircle.Billing.Invoice,
        join: invd in FullCircle.Billing.InvoiceDetail,
        on: invd.invoice_id == inv.id,
        join: gd in ^goods_qry,
        on: gd.id == invd.good_id,
        join: pkg in FullCircle.Product.Packaging,
        on: pkg.id == invd.package_id,
        where: inv.invoice_date >= ^fdate,
        where: inv.invoice_date <= ^tdate,
        where: inv.company_id == ^com_id,
        select: %{
          good: gd.name,
          pack_name: pkg.name,
          pack_qty: sum(invd.package_qty),
          qty: sum(invd.quantity),
          unit: gd.unit,
          price: avg((invd.unit_price * invd.quantity - invd.discount) / invd.quantity),
          amount: sum((invd.unit_price * invd.quantity - invd.discount))
        },
        group_by: [gd.name, pkg.name, gd.unit]
      )

    inv = if(cont, do: from(i in inv, where: i.contact_id == ^cont.id), else: inv)

    rec =
      from(inv in FullCircle.ReceiveFund.Receipt,
        join: invd in FullCircle.ReceiveFund.ReceiptDetail,
        on: invd.receipt_id == inv.id,
        join: gd in ^goods_qry,
        on: gd.id == invd.good_id,
        join: pkg in FullCircle.Product.Packaging,
        on: pkg.id == invd.package_id,
        where: inv.receipt_date >= ^fdate,
        where: inv.receipt_date <= ^tdate,
        where: inv.company_id == ^com_id,
        select: %{
          good: gd.name,
          pack_name: pkg.name,
          pack_qty: sum(invd.package_qty),
          qty: sum(invd.quantity),
          unit: gd.unit,
          price: avg((invd.unit_price * invd.quantity - invd.discount) / invd.quantity),
          amount: sum((invd.unit_price * invd.quantity - invd.discount))
        },
        group_by: [gd.name, pkg.name, gd.unit]
      )

    rec = if(cont, do: from(i in rec, where: i.contact_id == ^cont.id), else: rec)

    uni = union_all(rec, ^inv)

    from(u in subquery(uni),
      select: %{
        good: u.good,
        pack_name: u.pack_name,
        pack_qty: sum(u.pack_qty),
        qty: sum(u.qty),
        avg_qty:
          fragment(
            "sum(?) / sum(case when ? = 0 then 1 else ? end)",
            u.qty,
            u.pack_qty,
            u.pack_qty
          ),
        unit: u.unit,
        price: avg(u.price * u.qty / u.qty),
        amount: sum(u.amount)
      },
      group_by: [u.good, u.pack_name, u.unit],
      order_by: u.good
    )
    |> Repo.all()
  end

  def transport_commission(tags, fdate, tdate, com_id) do
    tag = tags |> String.split(" ", trim: true) |> Enum.at(0)

    inv_ids_qry =
      from(i in FullCircle.Billing.Invoice,
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
