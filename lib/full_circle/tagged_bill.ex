defmodule FullCircle.TaggedBill do
  import Ecto.Query, warn: false

  alias FullCircle.Repo
  alias FullCircle.Accounting.Contact

  def goods_sales_report(contact, goods, fdate, tdate, com_id) do
    good_lst = goods |> String.split(",") |> Enum.map(fn x -> String.trim(x) end)
    cont = FullCircle.Accounting.get_contact_by_name(contact, %{id: com_id}, nil)

    goods_qry =
      if good_lst != [""] do
        from(gd in FullCircle.Product.Good,
          where: gd.name in ^good_lst
        )
      else
        from(gd in FullCircle.Product.Good)
      end

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
          doc_id: inv.id,
          doc_type: "Invoice",
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
          doc_id: inv.id,
          doc_type: "Receipt",
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

    union_all(rec, ^inv) |> order_by([4, 2, 3]) |> Repo.all()
  end

  def goods_sales_summary_report(contact, goods, fdate, tdate, com_id) do
    good_lst = goods |> String.split(",") |> Enum.map(fn x -> String.trim(x) end)
    cont = FullCircle.Accounting.get_contact_by_name(contact, %{id: com_id}, nil)

    goods_qry =
      if good_lst != [""] do
        from(gd in FullCircle.Product.Good,
          where: gd.name in ^good_lst
        )
      else
        from(gd in FullCircle.Product.Good)
      end

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
          amount: sum(invd.unit_price * invd.quantity - invd.discount)
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
          amount: sum(invd.unit_price * invd.quantity - invd.discount)
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
    tag_list = resolve_tags(tags, fdate, tdate, com_id)

    tag_list
    |> Enum.flat_map(fn tag -> rows_for_tag(tag, fdate, tdate, com_id) end)
    |> Enum.sort_by(fn x -> {x.employee_tag, x.invoice_date, x.doc_no} end)
  end

  defp resolve_tags(tags, fdate, tdate, com_id) do
    trimmed = String.trim(tags || "")

    if String.downcase(trimmed) == "all" do
      discover_tags(fdate, tdate, com_id)
    else
      trimmed
      |> String.split(~r/\s+/, trim: true)
      |> Enum.map(&String.trim_leading(&1, "#"))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
    end
  end

  defp discover_tags(fdate, tdate, com_id) do
    inv_tags =
      from(i in FullCircle.Billing.Invoice,
        where: i.company_id == ^com_id,
        where: i.invoice_date >= ^fdate,
        where: i.invoice_date <= ^tdate,
        select:
          fragment(
            "string_to_array(coalesce(?, '') || ' ' || coalesce(?, ''), ' ')",
            i.loader_tags,
            i.delivery_man_tags
          )
      )

    pur_inv_tags =
      from(i in FullCircle.Billing.PurInvoice,
        where: i.company_id == ^com_id,
        where: i.pur_invoice_date >= ^fdate,
        where: i.pur_invoice_date <= ^tdate,
        select:
          fragment(
            "string_to_array(coalesce(?, '') || ' ' || coalesce(?, ''), ' ')",
            i.loader_tags,
            i.delivery_man_tags
          )
      )

    union_all(inv_tags, ^pur_inv_tags)
    |> Repo.all()
    |> List.flatten()
    |> Enum.map(&(&1 |> String.trim() |> String.trim_leading("#")))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp rows_for_tag(tag, fdate, tdate, com_id) do
    pattern = "(^|[[:space:]])#?#{Regex.escape(tag)}([[:space:]]|$)"

    inv_ids_qry =
      from(i in FullCircle.Billing.Invoice,
        where:
          fragment(
            "(? ~* ?) or (? ~* ?)",
            i.loader_tags,
            ^pattern,
            i.delivery_man_tags,
            ^pattern
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
            "(? ~* ?) or (? ~* ?)",
            i.loader_tags,
            ^pattern,
            i.delivery_man_tags,
            ^pattern
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
          doc_no: inv.e_inv_internal_id,
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
          inv.e_inv_internal_id,
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
        loader_tags: String.split(x.loader_tags || "") |> Enum.uniq() |> Enum.join(", "),
        loader_tags_count: String.split(x.loader_tags || "") |> Enum.uniq() |> Enum.count(),
        delivery_man_tags:
          String.split(x.delivery_man_tags || "") |> Enum.uniq() |> Enum.join(", "),
        delivery_man_tags_count:
          String.split(x.delivery_man_tags || "") |> Enum.uniq() |> Enum.count()
      })
    end)
    |> Enum.map(fn x ->
      Map.merge(x, %{
        employee_tag: tag,
        load_wages:
          if x.loader_tags_count > 0 and tag_in?(tag, x.loader_tags) do
            (wage_amount(x.loader_wages_tags) * Decimal.to_float(x.quantity) /
               x.loader_tags_count)
            |> Float.round(2)
          else
            0.0
          end,
        delivery_wages:
          if x.delivery_man_tags_count > 0 and tag_in?(tag, x.delivery_man_tags) do
            (wage_amount(x.delivery_wages_tags) * Decimal.to_float(x.quantity) /
               x.delivery_man_tags_count)
            |> Float.round(2)
          else
            0.0
          end
      })
    end)
  end

  defp tag_in?(tag, data_tags_str) do
    data_tags_str
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.trim_leading("#")))
    |> Enum.member?(tag)
  end

  defp wage_amount(wages_str) do
    {wage, _} =
      (Regex.scan(~r/(?<=\[).+?(?=\])/, wages_str || "")
       |> List.flatten()
       |> List.first() || "0.0")
      |> Float.parse()

    wage
  end
end
