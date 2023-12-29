defmodule FullCircle.Product do
  import Ecto.Query, warn: false
  import FullCircle.Helpers
  import FullCircle.Authorization

  alias Ecto.Multi
  alias FullCircle.Accounting.{Account, TaxCode, Contact}

  alias FullCircle.Product.{
    Good,
    Packaging,
    Order,
    OrderDetail,
    Load,
    LoadDetail,
    Delivery,
    DeliveryDetail
  }

  alias FullCircle.{Repo, Sys, StdInterface}

  # Deliveries

  def get_print_deliveries!(ids, com, user) do
    from(inv in Delivery,
      join: comp in subquery(Sys.user_company(com, user)),
      on: comp.id == inv.company_id,
      join: cont in Contact,
      on: cont.id == inv.customer_id,
      where: inv.id in ^ids,
      preload: [delivery_details: ^delivery_details()],
      preload: [customer: cont],
      select: inv,
      select_merge: %{customer_name: cont.name}
    )
    |> Repo.all()
  end

  def get_delivery_line_by_id_index_component_field!(line_id, com, user) do
    from(i in subquery(delivery_raw_query(com, user)),
      where: i.line_id == ^line_id
    )
    |> Repo.one!()
  end

  def delivery_index_query(terms, delivery_date_form, com, user,
        page: page,
        per_page: per_page
      ) do
    qry =
      from(inv in subquery(delivery_raw_query(com, user)))

    qry =
      if terms != "" do
        from inv in subquery(qry),
          order_by:
            ^similarity_order([:delivery_no, :customer_name, :status, :goods_name], terms),
          order_by: [desc: :updated_at]
      else
        qry |> order_by(desc: :updated_at)
      end

    qry =
      if delivery_date_form != "" do
        from inv in qry,
          where: inv.delivery_date_form >= ^delivery_date_form,
          order_by: inv.delivery_date
      else
        qry
      end

    qry |> offset((^page - 1) * ^per_page) |> limit(^per_page) |> Repo.all()
  end

  # def delivery_lines_to_invoice_lines(ids) do
  #   from(ddd in DeliveryDetail,
  #     join: gd in Good,
  #     on: gd.id == ddd.good_id,
  #     join: pkg in Packaging,
  #     on: pkg.id == ddd.package_id,
  #     where: ddd.id in ^ids,
  #     order_by: ddd._persistent_id,
  #     select: %{
  #       good_name: gd.name,
  #       good_id: gd.id,
  #       package_id: pkg.id,
  #       delivery_detail_id: ddd.id,
  #       package_name: pkg.name,
  #       load_pack_qty: ddd.pack_qty,
  #       load_qty: ddd.delivery_qty,
  #       unit: gd.unit,
  #       descriptions: ddd.descriptions
  #     }
  #   )
  #   |> Repo.all()
  # end

  def load_lines_to_delivery_lines(ids) do
    from(ddd in LoadDetail,
      join: gd in Good,
      on: gd.id == ddd.good_id,
      join: pkg in Packaging,
      on: pkg.id == ddd.package_id,
      where: ddd.id in ^ids,
      order_by: ddd._persistent_id,
      select: %{
        good_name: gd.name,
        good_id: gd.id,
        package_id: pkg.id,
        delivery_detail_id: ddd.id,
        package_name: pkg.name,
        delivery_pack_qty: ddd.load_pack_qty,
        delivery_qty: ddd.load_qty,
        unit: gd.unit,
        descriptions: ddd.descriptions
      }
    )
    |> Repo.all()
  end

  defp delivery_raw_query(com, user) do
    from(dd in Delivery,
      join: ddd in DeliveryDetail,
      on: dd.id == ddd.delivery_id,
      join: cont in Contact,
      on: cont.id == dd.customer_id,
      join: comp in subquery(Sys.user_company(com, user)),
      on: comp.id == dd.company_id,
      join: good in Good,
      on: good.id == ddd.good_id,
      left_join: pkg in Packaging,
      on: pkg.id == ddd.package_id,
      left_join: ldd in LoadDetail,
      on: ddd.load_detail_id == ldd.id,
      left_join: ld in Load,
      on: ld.id == ldd.load_id,
      left_join: odd in OrderDetail,
      on: ldd.order_detail_id == odd.id,
      left_join: od in Order,
      on: od.id == odd.order_id,
      left_join: ship in Contact,
      on: ship.id == ld.shipper_id,
      left_join: sup in Contact,
      on: sup.id == ld.supplier_id,
      select: %{
        checked: false,
        id: dd.id,
        line_id: ddd.id,
        customer_name: cont.name,
        delivery_no: dd.delivery_no,
        delivery_date: dd.delivery_date,
        descriptions: dd.descriptions,
        status: ddd.status,
        good_name: good.name,
        package: pkg.name,
        delivery_qty: ddd.delivery_qty,
        delivery_pack_qty: ddd.delivery_pack_qty,
        order_qty: coalesce(sum(odd.order_qty), 0),
        loaded_qty: coalesce(sum(ldd.load_qty), 0),
        unit: good.unit,
        updated_at: dd.updated_at
      },
      group_by: [dd.id, ddd.id, cont.id, good.id, pkg.id]
    )
  end

  def get_delivery!(id, company, user) do
    Repo.one(
      from dev in Delivery,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == dev.company_id,
        join: cont in Contact,
        on: cont.id == dev.customer_id,
        where: dev.id == ^id,
        preload: [delivery_details: ^delivery_details()],
        select: dev,
        select_merge: %{customer_name: cont.name}
    )
  end

  def get_delivery_full_map!(id, company) do
    from(dd in Delivery,
      join: ddd in DeliveryDetail,
      on: dd.id == ddd.delivery_id,
      join: cont in Contact,
      on: cont.id == dd.customer_id,
      join: good in Good,
      on: good.id == ddd.good_id,
      left_join: pkg in Packaging,
      on: pkg.id == ddd.package_id,
      left_join: ldd in LoadDetail,
      on: ddd.id == ldd.delivery_detail_id,
      left_join: ld in Load,
      on: ld.id == ldd.load_id,
      left_join: ship in Contact,
      on: ship.id == ld.shipper_id,
      left_join: sup in Contact,
      on: sup.id == ld.supplier_id,
      left_join: odd in OrderDetail,
      on: ldd.order_detail_id == odd.id,
      left_join: od in Order,
      on: ddd.delivery_id == dd.id,
      where: dd.id == ^id,
      where: dd.company_id == ^company.id,
      preload: [customer: cont],
      preload: [
        delivery_details:
          {ddd,
           [
             good: good,
             load_details:
               {ldd,
                [
                  load: {ld, [supplier: sup, shipper: ship]},
                  order_details: {odd, [order: od]}
                ]}
           ]}
      ]
    )
    |> Repo.one()
  end

  defp delivery_details do
    from ddd in DeliveryDetail,
      join: good in Good,
      on: good.id == ddd.good_id,
      left_join: pkg in Packaging,
      on: pkg.id == ddd.package_id,
      order_by: ddd._persistent_id,
      select: ddd,
      select_merge: %{
        package_name: pkg.name,
        package_id: pkg.id,
        unit: good.unit,
        good_name: good.name,
        unit_multiplier: pkg.unit_multiplier,
        delivery_pack_qty: ddd.delivery_pack_qty,
        delivery_qty: ddd.delivery_qty,
        unit_price: ddd.unit_price,
        descriptions: ddd.descriptions
      }
  end

  def create_delivery(attrs, com, user) do
    case can?(user, :create_delivery, com) do
      true ->
        Multi.new()
        |> create_delivery_multi(attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  end

  def create_delivery_multi(multi, attrs, com, user) do
    gapless_name = String.to_atom("update_gapless_doc" <> gen_temp_id())
    note_name = :create_delivery

    multi
    |> get_gapless_doc_id(gapless_name, "Delivery", "DO", com)
    |> Multi.insert(
      note_name,
      fn mty ->
        doc = Map.get(mty, gapless_name)

        StdInterface.changeset(
          Delivery,
          %Delivery{},
          Map.merge(attrs, %{"delivery_no" => doc}),
          com
        )
      end
    )
    |> Multi.insert("#{note_name}_log", fn %{^note_name => entity} ->
      FullCircle.Sys.log_changeset(
        note_name,
        entity,
        Map.merge(attrs, %{"delivery_no" => entity.delivery_no}),
        com,
        user
      )
    end)
  end

  def update_delivery(%Delivery{} = delivery, attrs, com, user) do
    case can?(user, :update_delivery, com) do
      true ->
        Multi.new()
        |> update_delivery_multi(delivery, attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  rescue
    e in Postgrex.Error ->
      {:sql_error, e.postgres.message}
  end

  def update_delivery_multi(multi, delivery, attrs, com, user) do
    note_name = :update_delivery

    multi
    |> Multi.update(
      note_name,
      StdInterface.changeset(Delivery, delivery, attrs, com)
    )
    |> Sys.insert_log_for(note_name, attrs, com, user)
  end

  # loads

  def get_print_loads!(ids, com, user) do
    from(inv in Load,
      join: comp in subquery(Sys.user_company(com, user)),
      on: comp.id == inv.company_id,
      join: cont in Contact,
      on: cont.id == inv.customer_id,
      where: inv.id in ^ids,
      preload: [load_details: ^load_details()],
      preload: [customer: cont],
      select: inv,
      select_merge: %{customer_name: cont.name}
    )
    |> Repo.all()
  end

  def get_load_by_id_index_component_field!(id_line_id, com, user) do
    [id, line_id] = id_line_id |> String.split("_")

    from(i in subquery(load_raw_query(com, user)),
      where: i.id == ^id,
      where: i.line_id == ^line_id
    )
    |> Repo.one!()
  end

  def load_index_query(terms, load_date_form, com, user,
        page: page,
        per_page: per_page
      ) do
    qry =
      from(inv in subquery(load_raw_query(com, user)))

    qry =
      if terms != "" do
        from inv in subquery(qry),
          order_by:
            ^similarity_order(
              [:load_no, :supplier_name, :shipper_name, :status, :goods_name],
              terms
            ),
          order_by: [desc: :updated_at]
      else
        qry |> order_by(desc: :updated_at)
      end

    qry =
      if load_date_form != "" do
        from inv in qry,
          where: inv.load_date >= ^load_date_form,
          order_by: inv.load_date
      else
        qry
      end

    qry |> offset((^page - 1) * ^per_page) |> limit(^per_page) |> Repo.all()
  end

  defp load_raw_query(com, user) do
    from(ld in Load,
      join: ldd in LoadDetail,
      on: ld.id == ldd.load_id,
      join: comp in subquery(Sys.user_company(com, user)),
      on: comp.id == ld.company_id,
      join: good in Good,
      on: good.id == ldd.good_id,
      left_join: pkg in Packaging,
      on: pkg.id == ldd.package_id,
      left_join: ship in Contact,
      on: ship.id == ld.shipper_id,
      left_join: sup in Contact,
      on: sup.id == ld.supplier_id,
      left_join: odd in OrderDetail,
      on: odd.id == ldd.order_detail_id,
      left_join: od in Order,
      on: od.id == odd.order_id,
      left_join: cust in Contact,
      on: cust.id == od.customer_id,
      select: %{
        checked: false,
        id: ld.id,
        line_id: ldd.id,
        supplier_name: sup.name,
        shipper_name: ship.name,
        lorry: ld.lorry,
        load_no: ld.load_no,
        load_date: ld.load_date,
        descriptions: ld.descriptions,
        loader_tags: ld.loader_tags,
        loader_wages_tags: ld.loader_wages_tags,
        status: ldd.status,
        good_name: good.name,
        package: pkg.name,
        load_qty: ldd.load_qty,
        load_pack_qty: ldd.load_pack_qty,
        unit: good.unit,
        updated_at: ld.updated_at,
        customer: cust.name,
        order_no: od.order_no,
        order_id: od.id,
        order_detail_id: odd.id
      }
    )
  end

  def get_load!(id, company, user) do
    Repo.one(
      from ld in Load,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == ld.company_id,
        left_join: ship in Contact,
        on: ship.id == ld.shipper_id,
        left_join: sup in Contact,
        on: sup.id == ld.supplier_id,
        where: ld.id == ^id,
        preload: [load_details: ^load_details()],
        select: ld,
        select_merge: %{shipper_name: ship.name, supplier_name: sup.name}
    )
  end

  defp load_details do
    from invd in LoadDetail,
      join: good in Good,
      on: good.id == invd.good_id,
      left_join: pkg in Packaging,
      on: pkg.id == invd.package_id,
      order_by: invd._persistent_id,
      select: invd,
      select_merge: %{
        package_name: pkg.name,
        package_id: pkg.id,
        unit: good.unit,
        good_name: good.name,
        unit_multiplier: pkg.unit_multiplier,
        load_pack_qty: invd.load_pack_qty,
        load_qty: invd.load_qty,
        descriptions: invd.descriptions,
        status: invd.status
      }
  end

  def create_load(attrs, com, user) do
    case can?(user, :create_load, com) do
      true ->
        Multi.new()
        |> create_load_multi(attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  end

  def create_load_multi(multi, attrs, com, user) do
    gapless_name = String.to_atom("update_gapless_doc" <> gen_temp_id())
    note_name = :create_load

    multi
    |> get_gapless_doc_id(gapless_name, "Load", "LD", com)
    |> Multi.insert(
      note_name,
      fn mty ->
        doc = Map.get(mty, gapless_name)

        StdInterface.changeset(
          Load,
          %Load{},
          Map.merge(attrs, %{"load_no" => doc}),
          com
        )
      end
    )
    |> Multi.insert("#{note_name}_log", fn %{^note_name => entity} ->
      FullCircle.Sys.log_changeset(
        note_name,
        entity,
        Map.merge(attrs, %{"load_no" => entity.load_no}),
        com,
        user
      )
    end)
  end

  def update_load(%Load{} = load, attrs, com, user) do
    case can?(user, :update_load, com) do
      true ->
        Multi.new()
        |> update_load_multi(load, attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  rescue
    e in Postgrex.Error ->
      {:sql_error, e.postgres.message}
  end

  def update_load_multi(multi, load, attrs, com, user) do
    note_name = :update_load

    multi
    |> Multi.update(
      note_name,
      StdInterface.changeset(Load, load, attrs, com)
    )
    |> Sys.insert_log_for(note_name, attrs, com, user)
  end

  #  Orders

  def get_print_orders!(ids, com, user) do
    from(inv in Order,
      join: comp in subquery(Sys.user_company(com, user)),
      on: comp.id == inv.company_id,
      join: cont in Contact,
      on: cont.id == inv.customer_id,
      where: inv.id in ^ids,
      preload: [order_details: ^order_details()],
      preload: [customer: cont],
      select: inv,
      select_merge: %{customer_name: cont.name}
    )
    |> Repo.all()
  end

  def get_order_line_by_id_index_component_field!(line_id, com, user) do
    from(i in subquery(order_raw_query(com, user)),
      where: i.line_id == ^line_id
    )
    |> Repo.one!()
  end

  def order_index_query(terms, order_date_form, etd_date_form, com, user,
        page: page,
        per_page: per_page
      ) do
    qry =
      from(inv in subquery(order_raw_query(com, user)))

    qry =
      if terms != "" do
        from inv in subquery(qry),
          order_by: ^similarity_order([:order_no, :customer_name, :status, :goods_name], terms),
          order_by: [desc: :updated_at]
      else
        qry |> order_by(desc: :updated_at)
      end

    qry =
      if order_date_form != "" do
        from inv in qry,
          where: inv.order_date_form >= ^order_date_form,
          order_by: inv.order_date_form
      else
        qry
      end

    qry =
      if etd_date_form != "" do
        from inv in qry, where: inv.etd_date >= ^etd_date_form, order_by: inv.etd_date_form
      else
        qry
      end

    qry |> offset((^page - 1) * ^per_page) |> limit(^per_page) |> Repo.all()
  end

  def order_lines_to_load_lines(ids) do
    from(odd in OrderDetail,
      join: od in Order,
      on: odd.order_id == od.id,
      join: cust in Contact,
      on: cust.id == od.customer_id,
      join: gd in Good,
      on: gd.id == odd.good_id,
      join: pkg in Packaging,
      on: pkg.id == odd.package_id,
      where: odd.id in ^ids,
      order_by: odd._persistent_id,
      select: %{
        customer_name: cust.name,
        good_name: gd.name,
        good_id: gd.id,
        package_id: pkg.id,
        order_detail_id: odd.id,
        package_name: pkg.name,
        load_pack_qty: odd.order_pack_qty,
        load_qty: odd.order_qty,
        unit: gd.unit,
        descriptions: odd.descriptions
      }
    )
    |> Repo.all()
  end

  defp order_raw_query(com, user) do
    from(od in Order,
      join: odd in OrderDetail,
      on: od.id == odd.order_id,
      join: cont in Contact,
      on: cont.id == od.customer_id,
      join: comp in subquery(Sys.user_company(com, user)),
      on: comp.id == od.company_id,
      join: good in Good,
      on: good.id == odd.good_id,
      left_join: pkg in Packaging,
      on: pkg.id == odd.package_id,
      left_join: ldd in LoadDetail,
      on: odd.id == ldd.order_detail_id,
      left_join: ld in Load,
      on: ld.id == ldd.load_id,
      left_join: ddd in DeliveryDetail,
      on: ldd.id == ddd.load_detail_id,
      left_join: dd in Delivery,
      on: dd.id == ddd.delivery_id,
      left_join: ship in Contact,
      on: ship.id == ld.shipper_id,
      left_join: sup in Contact,
      on: sup.id == ld.supplier_id,
      select: %{
        checked: false,
        id: od.id,
        line_id: odd.id,
        customer_name: cont.name,
        order_no: od.order_no,
        order_date: od.order_date,
        etd_date: od.etd_date,
        descriptions: od.descriptions,
        status: odd.status,
        good_name: good.name,
        package: pkg.name,
        order_qty: odd.order_qty,
        order_pack_qty: odd.order_pack_qty,
        delivered_qty: coalesce(sum(ddd.delivery_qty), 0),
        loaded_qty: coalesce(sum(ldd.load_qty), 0),
        unit: good.unit,
        updated_at: od.updated_at
      },
      group_by: [od.id, odd.id, cont.id, good.id, pkg.id]
    )
  end

  def get_order!(id, company, user) do
    Repo.one(
      from inv in Order,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == inv.company_id,
        join: cont in Contact,
        on: cont.id == inv.customer_id,
        where: inv.id == ^id,
        preload: [order_details: ^order_details()],
        select: inv,
        select_merge: %{customer_name: cont.name}
    )
  end

  def get_order_full_map!(id, company) do
    from(od in Order,
      join: odd in OrderDetail,
      on: od.id == odd.order_id,
      join: cont in Contact,
      on: cont.id == od.customer_id,
      join: good in Good,
      on: good.id == odd.good_id,
      left_join: pkg in Packaging,
      on: pkg.id == odd.package_id,
      left_join: ldd in LoadDetail,
      on: odd.id == ldd.order_detail_id,
      left_join: ld in Load,
      on: ld.id == ldd.load_id,
      left_join: ship in Contact,
      on: ship.id == ld.shipper_id,
      left_join: sup in Contact,
      on: sup.id == ld.supplier_id,
      left_join: ddd in DeliveryDetail,
      on: ddd.load_detail_id == ldd.id,
      left_join: dd in Delivery,
      on: ddd.delivery_id == dd.id,
      where: od.id == ^id,
      where: od.company_id == ^company.id,
      preload: [customer: cont],
      preload: [
        order_details:
          {odd,
           [
             good: good,
             load_details:
               {ldd,
                [
                  load: {ld, [supplier: sup, shipper: ship]},
                  delivery_details: {ddd, [delivery: dd]}
                ]}
           ]}
      ]
    )
    |> Repo.one()
  end

  defp order_details do
    from invd in OrderDetail,
      join: good in Good,
      on: good.id == invd.good_id,
      left_join: pkg in Packaging,
      on: pkg.id == invd.package_id,
      order_by: invd._persistent_id,
      select: invd,
      select_merge: %{
        package_name: pkg.name,
        package_id: pkg.id,
        unit: good.unit,
        good_name: good.name,
        unit_multiplier: pkg.unit_multiplier,
        order_pack_qty: invd.order_pack_qty,
        order_qty: invd.order_qty,
        unit_price: invd.unit_price,
        descriptions: invd.descriptions
      }
  end

  def create_order(attrs, com, user) do
    case can?(user, :create_order, com) do
      true ->
        Multi.new()
        |> create_order_multi(attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  end

  def create_order_multi(multi, attrs, com, user) do
    gapless_name = String.to_atom("update_gapless_doc" <> gen_temp_id())
    note_name = :create_order

    multi
    |> get_gapless_doc_id(gapless_name, "Order", "OR", com)
    |> Multi.insert(
      note_name,
      fn mty ->
        doc = Map.get(mty, gapless_name)

        StdInterface.changeset(
          Order,
          %Order{},
          Map.merge(attrs, %{"order_no" => doc}),
          com
        )
      end
    )
    |> Multi.insert("#{note_name}_log", fn %{^note_name => entity} ->
      FullCircle.Sys.log_changeset(
        note_name,
        entity,
        Map.merge(attrs, %{"order_no" => entity.order_no}),
        com,
        user
      )
    end)
  end

  def update_order(%Order{} = load, attrs, com, user) do
    case can?(user, :update_order, com) do
      true ->
        Multi.new()
        |> update_order_multi(load, attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  rescue
    e in Postgrex.Error ->
      {:sql_error, e.postgres.message}
  end

  def update_order_multi(multi, load, attrs, com, user) do
    note_name = :update_order

    multi
    |> Multi.update(
      note_name,
      StdInterface.changeset(Order, load, attrs, com)
    )
    |> Sys.insert_log_for(note_name, attrs, com, user)
  end

  # GOODS

  def get_good!(id, company, user) do
    from(good in subquery(good_query(company, user)),
      preload: :packagings,
      where: good.id == ^id
    )
    |> Repo.one!()
  end

  def get_good_by_name(name, company, user) do
    name = name |> String.trim()

    from(good in subquery(good_query(company, user)),
      left_join: pack in Packaging,
      on: pack.good_id == good.id,
      where: good.name == ^name,
      select: %{
        id: good.id,
        value: good.name,
        unit: good.unit,
        package_name: pack.name,
        package_id: pack.id,
        unit_multiplier: pack.unit_multiplier,
        sales_account_name: good.sales_account_name,
        purchase_account_name: good.purchase_account_name,
        sales_account_id: good.sales_account_id,
        purchase_account_id: good.purchase_account_id,
        sales_tax_code_name: good.sales_tax_code_name,
        purchase_tax_code_name: good.purchase_tax_code_name,
        sales_tax_code_id: good.sales_tax_code_id,
        purchase_tax_code_id: good.purchase_tax_code_id,
        sales_tax_rate: good.sales_tax_rate,
        purchase_tax_rate: good.purchase_tax_rate
      },
      order_by: good.name,
      order_by: [desc: pack.default],
      order_by: pack.id,
      distinct: good.name
    )
    |> Repo.one()
  end

  def good_names(terms, company, user) do
    from(good in subquery(good_query(company, user)),
      where: ilike(good.name, ^"%#{terms}%"),
      select: %{
        id: good.id,
        value: good.name
      },
      order_by: good.name
    )
    |> Repo.all()
  end

  def get_packaging_by_name(terms, good_id) do
    terms = terms |> String.trim()

    from(pack in Packaging,
      where: pack.name == ^terms,
      where: pack.good_id == ^good_id,
      select: %{
        id: pack.id,
        value: pack.name,
        unit_multiplier: pack.unit_multiplier,
        default: pack.default
      }
    )
    |> Repo.one()
  end

  def package_names(terms, good_id) do
    from(pack in Packaging,
      where: ilike(pack.name, ^"%#{terms}%"),
      where: pack.good_id == ^good_id,
      select: %{
        id: pack.id,
        value: pack.name,
        unit_multiplier: pack.unit_multiplier,
        default: pack.default
      }
    )
    |> Repo.all()
  end

  defp good_query(company, user) do
    from(good in Good,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == good.company_id,
      left_join: sac in Account,
      on: sac.id == good.sales_account_id,
      left_join: pac in Account,
      on: pac.id == good.purchase_account_id,
      left_join: stc in TaxCode,
      on: stc.id == good.sales_tax_code_id,
      left_join: ptc in TaxCode,
      on: ptc.id == good.purchase_tax_code_id,
      select: %Good{
        id: good.id,
        name: good.name,
        unit: good.unit,
        sales_account_name: sac.name,
        purchase_account_name: pac.name,
        sales_account_id: sac.id,
        purchase_account_id: pac.id,
        sales_tax_code_name: stc.code,
        purchase_tax_code_name: ptc.code,
        sales_tax_code_id: stc.id,
        purchase_tax_code_id: ptc.id,
        sales_tax_rate: stc.rate,
        purchase_tax_rate: ptc.rate,
        descriptions: good.descriptions,
        inserted_at: good.inserted_at,
        updated_at: good.updated_at
      }
    )
  end

  def good_index_query("", company, user, page: page, per_page: per_page) do
    from(good in subquery(good_query(company, user)),
      offset: ^((page - 1) * per_page),
      limit: ^per_page,
      preload: :packagings,
      order_by: [desc: good.updated_at]
    )
    |> Repo.all()
  end

  def good_index_query(terms, company, user, page: page, per_page: per_page) do
    from(good in subquery(good_query(company, user)),
      offset: ^((page - 1) * per_page),
      limit: ^per_page,
      preload: :packagings,
      order_by:
        ^similarity_order(
          ~w(name unit purchase_account_name sales_account_name sales_tax_code_name purchase_tax_code_name)a,
          terms
        )
    )
    |> Repo.all()
  end
end
