defmodule FullCircle.Trading.Settlement do
  @moduledoc """
  Trading desk settlement.

  - **Phase A:** customer Invoice from completed sales drops
  - **Phase B:** supplier PurInvoice from completed commercial loads
  - **Phase C:** transport agent PurInvoice from haul lines (drop + origin load)

  Trading remains logistics truth; finance docs remain AR/AP/GL truth.
  Eligibility gate for billing: trip `status == "completed"` only.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias FullCircle.Repo
  alias FullCircle.Authorization
  alias FullCircle.Sys
  alias FullCircle.Product
  alias FullCircle.Product.Good
  alias FullCircle.Billing
  alias FullCircle.Billing.{Invoice, PurInvoice}
  alias FullCircle.Accounting
  alias FullCircle.Accounting.{Contact, TaxCode}
  alias FullCircle.StdInterface
  alias FullCircle.Trading.{
    Trip,
    TripDrop,
    TripLoad,
    SalesPosition,
    SupplyPosition,
    Location
  }

  # Preferred good names for agent haulage PurInvoice lines (not the grain product).
  # First match wins; if none exist, create "Haulage".
  @haulage_good_names [
    "Transport Services Purchase",
    "Transport Charges",
    "Note"
  ]

  @doc """
  Sales drops for the customer-invoicing board.

  Includes:
  - **draft / planned** trips (visible, not selectable)
  - **completed** trips not yet linked to an invoice (selectable when `actual_mt` present)

  Cancelled trips are excluded. Already-invoiced drops are excluded **unless**
  `:trip_id` is set (trip deep-link shows billed + unbilled for that trip).

  Each row has `invoiceable: true | false`. Only invoiceable rows may be billed.
  Settled rows carry `doc_id` / `doc_no` / `doc_kind` for linking to the Invoice.

  Options:
  - `:customer_id` — filter by sales customer
  - `:from_date` / `:to_date` — trip date range
  - `:trip_id` — single trip (desk deep-link; includes settled lines)
  """
  def list_uninvoiced_drops(company, user, opts \\ []) do
    if Authorization.can?(user, :view_trading, company) do
      customer_id = Keyword.get(opts, :customer_id)
      from_date = Keyword.get(opts, :from_date)
      to_date = Keyword.get(opts, :to_date)
      trip_id = Keyword.get(opts, :trip_id)
      include_settled? = present_id?(trip_id)

      from(d in TripDrop,
        join: t in Trip,
        on: t.id == d.trip_id,
        join: s in SalesPosition,
        on: s.id == d.sales_position_id,
        join: c in Contact,
        on: c.id == s.customer_id,
        join: g in Good,
        on: g.id == d.good_id,
        join: l in Location,
        on: l.id == d.location_id,
        left_join: inv in Invoice,
        on: inv.id == d.invoice_id,
        where: t.company_id == ^company.id,
        where: t.status in ["draft", "planned", "completed"],
        where: not is_nil(d.sales_position_id),
        order_by: [desc: t.date, asc: t.reference_no, asc: d.seq],
        select: %{
          id: d.id,
          planned_mt: d.planned_mt,
          actual_mt: d.actual_mt,
          seq: d.seq,
          trip_id: t.id,
          trip_date: t.date,
          trip_reference_no: t.reference_no,
          trip_status: t.status,
          sales_position_id: s.id,
          sales_title: s.title,
          unit_price: s.unit_price,
          customer_id: c.id,
          customer_name: c.name,
          good_id: g.id,
          good_name: g.name,
          good_unit: g.unit,
          location_id: l.id,
          location_name: l.name,
          doc_id: d.invoice_id,
          doc_no: inv.invoice_no,
          doc_kind: "invoice",
          invoiceable:
            t.status == "completed" and not is_nil(d.actual_mt) and is_nil(d.invoice_id)
        }
      )
      |> maybe_filter_customer(customer_id)
      |> maybe_filter_from_date(from_date)
      |> maybe_filter_to_date(to_date)
      |> maybe_filter_trip_id(trip_id)
      |> maybe_require_unset_invoice(include_settled?)
      |> Repo.all()
    else
      []
    end
  end

  @doc """
  Build Invoice form attrs from uninvoiced completed sales drops.

  All drops must be eligible and share the same customer.
  Returns `{:ok, attrs}` with string keys suitable for `Billing.create_invoice` / form.
  """
  def build_invoice_attrs_from_drop_ids(drop_ids, company, user)
      when is_list(drop_ids) do
    with :ok <- authorize_view(user, company),
         {:ok, drops} <- load_eligible_drops(drop_ids, company),
         :ok <- same_customer?(drops) do
      {:ok, invoice_attrs_from_drops(drops, company, user)}
    end
  end

  def build_invoice_attrs_from_drop_ids(_, _, _), do: {:error, :invalid_drops}

  @doc """
  Link eligible drops to an Invoice (sets `trip_drops.invoice_id`).

  Only updates rows that still have `invoice_id` nil. Returns
  `{:error, :drops_already_invoiced}` if fewer rows updated than expected.
  """
  def link_drops_to_invoice(drop_ids, invoice, company, user)
      when is_list(drop_ids) and drop_ids != [] do
    with :ok <- authorize_invoice(user, company),
         true <- invoice.company_id == company.id,
         {:ok, drops} <- load_eligible_drops(drop_ids, company),
         :ok <- same_customer?(drops),
         :ok <- customer_matches_invoice?(drops, invoice) do
      ids = Enum.map(drops, & &1.id)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {n, _} =
        from(d in TripDrop,
          where: d.id in ^ids,
          where: is_nil(d.invoice_id)
        )
        |> Repo.update_all(set: [invoice_id: invoice.id, updated_at: now])

      if n == length(ids) do
        {:ok, n}
      else
        {:error, :drops_already_invoiced}
      end
    else
      false -> :not_authorise
      other -> other
    end
  end

  def link_drops_to_invoice([], _invoice, _company, _user), do: {:error, :invalid_drops}
  def link_drops_to_invoice(_, _, _, _), do: {:error, :invalid_drops}

  @doc """
  Create Invoice and link drops in one transaction.

  `attrs` may override defaults from `build_invoice_attrs_from_drop_ids/3`
  (e.g. edited prices from the form). Drops are re-validated at write time.
  """
  def create_invoice_from_drops(drop_ids, attrs, company, user)
      when is_list(drop_ids) and drop_ids != [] do
    with :ok <- authorize_invoice(user, company),
         {:ok, drops} <- load_eligible_drops(drop_ids, company),
         :ok <- same_customer?(drops) do
      base = invoice_attrs_from_drops(drops, company, user)
      merged = deep_merge_string_maps(base, stringify_keys(attrs))

      Multi.new()
      |> Billing.create_invoice_multi(merged, company, user)
      |> Multi.run(:link_trading_drops, fn repo, %{create_invoice: inv} ->
        ids = Enum.map(drops, & &1.id)
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        {n, _} =
          from(d in TripDrop,
            where: d.id in ^ids,
            where: is_nil(d.invoice_id)
          )
          |> repo.update_all(set: [invoice_id: inv.id, updated_at: now])

        if n == length(ids) do
          {:ok, n}
        else
          {:error, :drops_already_invoiced}
        end
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{create_invoice: inv} = result} ->
          {:ok, Map.put(result, :create_invoice, inv)}

        {:error, :create_invoice, %Ecto.Changeset{} = cs, _} ->
          {:error, :create_invoice, cs, %{}}

        {:error, :link_trading_drops, reason, _} ->
          {:error, reason}

        {:error, step, reason, _} ->
          {:error, step, reason, %{}}
      end
    end
  end

  def create_invoice_from_drops(_, _, _, _), do: {:error, :invalid_drops}

  # --- Phase B: supplier PurInvoice from commercial loads ---

  @doc """
  Commercial loads for the supplier-billing board.

  Includes draft/planned (visible, not selectable) and completed unbilled
  loads with `supply_position_id` (selectable when `actual_mt` present).

  Already-billed loads are excluded **unless** `:trip_id` is set (includes
  settled lines with `doc_id` / `doc_no` / `doc_kind` for the PurInvoice).

  Options: `:supplier_id`, `:from_date`, `:to_date`, `:trip_id`
  """
  def list_unbilled_loads(company, user, opts \\ []) do
    if Authorization.can?(user, :view_trading, company) do
      supplier_id = Keyword.get(opts, :supplier_id)
      from_date = Keyword.get(opts, :from_date)
      to_date = Keyword.get(opts, :to_date)
      trip_id = Keyword.get(opts, :trip_id)
      include_settled? = present_id?(trip_id)

      from(l in TripLoad,
        join: t in Trip,
        on: t.id == l.trip_id,
        join: s in SupplyPosition,
        on: s.id == l.supply_position_id,
        join: c in Contact,
        on: c.id == s.supplier_id,
        join: g in Good,
        on: g.id == l.good_id,
        join: loc in Location,
        on: loc.id == l.location_id,
        left_join: pinv in PurInvoice,
        on: pinv.id == l.pur_invoice_id,
        where: t.company_id == ^company.id,
        where: t.status in ["draft", "planned", "completed"],
        where: not is_nil(l.supply_position_id),
        order_by: [desc: t.date, asc: t.reference_no, asc: l.seq],
        select: %{
          id: l.id,
          planned_mt: l.planned_mt,
          actual_mt: l.actual_mt,
          seq: l.seq,
          trip_id: t.id,
          trip_date: t.date,
          trip_reference_no: t.reference_no,
          trip_status: t.status,
          vehicle_number: t.vehicle_number,
          supply_position_id: s.id,
          supply_title: s.title,
          unit_price: s.unit_price,
          supplier_id: c.id,
          supplier_name: c.name,
          good_id: g.id,
          good_name: g.name,
          good_unit: g.unit,
          location_id: loc.id,
          location_name: loc.name,
          doc_id: l.pur_invoice_id,
          doc_no: pinv.pur_invoice_no,
          doc_kind: "pur_invoice",
          billable:
            t.status == "completed" and not is_nil(l.actual_mt) and is_nil(l.pur_invoice_id)
        }
      )
      |> maybe_filter_supplier(supplier_id)
      |> maybe_filter_load_from_date(from_date)
      |> maybe_filter_load_to_date(to_date)
      |> maybe_filter_trip_id(trip_id)
      |> maybe_require_unset_pur_invoice_load(include_settled?)
      |> Repo.all()
    else
      []
    end
  end

  def build_pur_invoice_attrs_from_load_ids(load_ids, company, user)
      when is_list(load_ids) do
    with :ok <- authorize_view(user, company),
         {:ok, loads} <- load_eligible_loads(load_ids, company),
         :ok <- same_supplier?(loads) do
      {:ok, pur_invoice_attrs_from_loads(loads, company, user)}
    end
  end

  def build_pur_invoice_attrs_from_load_ids(_, _, _), do: {:error, :invalid_loads}

  def create_pur_invoice_from_loads(load_ids, attrs, company, user)
      when is_list(load_ids) and load_ids != [] do
    with :ok <- authorize_pur_invoice(user, company),
         {:ok, loads} <- load_eligible_loads(load_ids, company),
         :ok <- same_supplier?(loads) do
      base = pur_invoice_attrs_from_loads(loads, company, user)
      merged = deep_merge_string_maps(base, stringify_keys(attrs))

      Multi.new()
      |> Billing.create_pur_invoice_multi(merged, company, user)
      |> Multi.run(:link_trading_loads, fn repo, %{create_pur_invoice: pinv} ->
        ids = Enum.map(loads, & &1.id)
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        {n, _} =
          from(l in TripLoad,
            where: l.id in ^ids,
            where: is_nil(l.pur_invoice_id)
          )
          |> repo.update_all(set: [pur_invoice_id: pinv.id, updated_at: now])

        if n == length(ids) do
          {:ok, n}
        else
          {:error, :loads_already_billed}
        end
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{create_pur_invoice: pinv} = result} ->
          {:ok, Map.put(result, :create_pur_invoice, pinv)}

        {:error, :create_pur_invoice, %Ecto.Changeset{} = cs, _} ->
          {:error, :create_pur_invoice, cs, %{}}

        {:error, :link_trading_loads, reason, _} ->
          {:error, reason}

        {:error, step, reason, _} ->
          {:error, step, reason, %{}}
      end
    end
  end

  def create_pur_invoice_from_loads(_, _, _, _), do: {:error, :invalid_loads}

  # --- Phase C: transport agent PurInvoice from haul lines (one per drop) ---

  @doc """
  Haul lines for transport-agent billing (agent trips only).

  Matching unit is one drop with resolved origin load location.
  Draft/planned shown (not selectable); completed + actual_mt billable.
  Already-billed haul lines excluded **unless** `:trip_id` is set.

  Options: `:agent_id`, `:from_date`, `:to_date`, `:trip_id`
  """
  def list_unbilled_transport_lines(company, user, opts \\ []) do
    if Authorization.can?(user, :view_trading, company) do
      agent_id = Keyword.get(opts, :agent_id)
      from_date = Keyword.get(opts, :from_date)
      to_date = Keyword.get(opts, :to_date)
      trip_id = Keyword.get(opts, :trip_id)
      include_settled? = present_id?(trip_id)

      drops =
        from(d in TripDrop,
          join: t in Trip,
          on: t.id == d.trip_id,
          join: agent in Contact,
          on: agent.id == t.transport_agent_id,
          join: g in Good,
          on: g.id == d.good_id,
          join: to_loc in Location,
          on: to_loc.id == d.location_id,
          left_join: pinv in PurInvoice,
          on: pinv.id == d.transport_pur_invoice_id,
          where: t.company_id == ^company.id,
          where: t.transport_mode == "agent",
          where: not is_nil(t.transport_agent_id),
          where: t.status in ["draft", "planned", "completed"],
          order_by: [desc: t.date, asc: t.reference_no, asc: d.seq],
          select: %{
            id: d.id,
            planned_mt: d.planned_mt,
            actual_mt: d.actual_mt,
            seq: d.seq,
            supply_position_id: d.supply_position_id,
            trip_id: t.id,
            trip_date: t.date,
            trip_reference_no: t.reference_no,
            trip_status: t.status,
            vehicle_number: t.vehicle_number,
            agent_id: agent.id,
            agent_name: agent.name,
            good_id: g.id,
            good_name: g.name,
            good_unit: g.unit,
            to_location_id: to_loc.id,
            to_location_name: to_loc.name,
            doc_id: d.transport_pur_invoice_id,
            doc_no: pinv.pur_invoice_no,
            doc_kind: "pur_invoice"
          }
        )
        |> maybe_filter_agent(agent_id)
        |> maybe_filter_transport_from_date(from_date)
        |> maybe_filter_transport_to_date(to_date)
        |> maybe_filter_trip_id(trip_id)
        |> maybe_require_unset_transport_pur_invoice(include_settled?)
        |> Repo.all()

      # Origin locations from trip loads (1:N / supply-matched N:N rules)
      trip_ids = drops |> Enum.map(& &1.trip_id) |> Enum.uniq()

      loads_by_trip =
        if trip_ids == [] do
          %{}
        else
          from(l in TripLoad,
            left_join: loc in Location,
            on: loc.id == l.location_id,
            where: l.trip_id in ^trip_ids,
            order_by: [asc: l.seq],
            select: %{
              trip_id: l.trip_id,
              supply_position_id: l.supply_position_id,
              location_id: l.location_id,
              location_name: loc.name,
              seq: l.seq
            }
          )
          |> Repo.all()
          |> Enum.group_by(& &1.trip_id)
        end

      Enum.map(drops, fn d ->
        origin = resolve_origin(d, Map.get(loads_by_trip, d.trip_id, []))

        Map.merge(d, %{
          from_location_id: origin && origin.location_id,
          from_location_name: origin && origin.location_name,
          billable:
            d.trip_status == "completed" and not is_nil(d.actual_mt) and is_nil(d.doc_id),
          # alias for shared settlement UI (party = agent)
          supplier_id: d.agent_id,
          supplier_name: d.agent_name,
          unit_price: nil,
          location_name: d.to_location_name,
          sales_title: nil,
          supply_title: nil
        })
      end)
    else
      []
    end
  end

  def build_pur_invoice_attrs_from_transport_drop_ids(drop_ids, company, user)
      when is_list(drop_ids) do
    with :ok <- authorize_view(user, company),
         {:ok, drops} <- load_eligible_transport_drops(drop_ids, company),
         :ok <- same_agent?(drops) do
      {:ok, pur_invoice_attrs_from_transport_drops(drops, company, user)}
    end
  end

  def build_pur_invoice_attrs_from_transport_drop_ids(_, _, _), do: {:error, :invalid_transport}

  def create_pur_invoice_from_transport_drops(drop_ids, attrs, company, user)
      when is_list(drop_ids) and drop_ids != [] do
    with :ok <- authorize_pur_invoice(user, company),
         {:ok, drops} <- load_eligible_transport_drops(drop_ids, company),
         :ok <- same_agent?(drops) do
      base = pur_invoice_attrs_from_transport_drops(drops, company, user)
      merged = deep_merge_string_maps(base, stringify_keys(attrs))

      Multi.new()
      |> Billing.create_pur_invoice_multi(merged, company, user)
      |> Multi.run(:link_transport_drops, fn repo, %{create_pur_invoice: pinv} ->
        ids = Enum.map(drops, & &1.id)
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        {n, _} =
          from(d in TripDrop,
            where: d.id in ^ids,
            where: is_nil(d.transport_pur_invoice_id)
          )
          |> repo.update_all(set: [transport_pur_invoice_id: pinv.id, updated_at: now])

        if n == length(ids) do
          {:ok, n}
        else
          {:error, :transport_already_billed}
        end
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{create_pur_invoice: pinv} = result} ->
          {:ok, Map.put(result, :create_pur_invoice, pinv)}

        {:error, :create_pur_invoice, %Ecto.Changeset{} = cs, _} ->
          {:error, :create_pur_invoice, cs, %{}}

        {:error, :link_transport_drops, reason, _} ->
          {:error, reason}

        {:error, step, reason, _} ->
          {:error, step, reason, %{}}
      end
    end
  end

  def create_pur_invoice_from_transport_drops(_, _, _, _), do: {:error, :invalid_transport}

  # --- Link hygiene: info, contact lock, unlink (no void/delete on finance docs) ---

  @doc """
  Settlement link summary for a customer Invoice.

  Link means "settled via this document", not a live mirror of qty/price.
  """
  def invoice_settlement_info(invoice_id, company) when is_binary(invoice_id) do
    rows =
      from(d in TripDrop,
        join: t in Trip,
        on: t.id == d.trip_id,
        where: d.invoice_id == ^invoice_id,
        where: t.company_id == ^company.id,
        order_by: [asc: t.reference_no, asc: d.seq],
        select: %{
          drop_id: d.id,
          actual_mt: d.actual_mt,
          trip_id: t.id,
          trip_reference_no: t.reference_no
        }
      )
      |> Repo.all()

    build_settlement_info(rows, :customer)
  end

  def invoice_settlement_info(_, _), do: empty_settlement_info()

  @doc """
  Settlement link summary for a PurInvoice (supplier loads and/or transport hauls).
  """
  def pur_invoice_settlement_info(pur_invoice_id, company) when is_binary(pur_invoice_id) do
    loads =
      from(l in TripLoad,
        join: t in Trip,
        on: t.id == l.trip_id,
        where: l.pur_invoice_id == ^pur_invoice_id,
        where: t.company_id == ^company.id,
        order_by: [asc: t.reference_no, asc: l.seq],
        select: %{
          load_id: l.id,
          actual_mt: l.actual_mt,
          trip_id: t.id,
          trip_reference_no: t.reference_no,
          kind: "supplier"
        }
      )
      |> Repo.all()

    transport =
      from(d in TripDrop,
        join: t in Trip,
        on: t.id == d.trip_id,
        where: d.transport_pur_invoice_id == ^pur_invoice_id,
        where: t.company_id == ^company.id,
        order_by: [asc: t.reference_no, asc: d.seq],
        select: %{
          drop_id: d.id,
          actual_mt: d.actual_mt,
          trip_id: t.id,
          trip_reference_no: t.reference_no,
          kind: "transport"
        }
      )
      |> Repo.all()

    rows = loads ++ transport
    info = build_settlement_info(rows, :purchase)
    Map.merge(info, %{supplier_load_count: length(loads), transport_drop_count: length(transport)})
  end

  def pur_invoice_settlement_info(_, _), do: empty_settlement_info()

  @doc """
  Returns `true` if attrs would change contact while the document is trading-linked.
  """
  def contact_change_blocked_for_invoice?(%Invoice{} = invoice, attrs) do
    invoice_settlement_info(invoice.id, %{id: invoice.company_id}).linked? and
      contact_id_changing?(invoice.contact_id, attrs)
  end

  def contact_change_blocked_for_invoice?(_, _), do: false

  def contact_change_blocked_for_pur_invoice?(%PurInvoice{} = pinv, attrs) do
    pur_invoice_settlement_info(pinv.id, %{id: pinv.company_id}).linked? and
      contact_id_changing?(pinv.contact_id, attrs)
  end

  def contact_change_blocked_for_pur_invoice?(_, _), do: false

  @doc """
  Clear trading FKs for this Invoice so drops reappear on settlement queues.
  Does not delete or void the Invoice.
  """
  def unlink_invoice_settlement(%Invoice{} = invoice, company, user) do
    with :ok <- authorize_invoice_update(user, company),
         true <- invoice.company_id == company.id do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      info = invoice_settlement_info(invoice.id, company)

      if not info.linked? do
        {:error, :not_linked}
      else
        Multi.new()
        |> Multi.run(:clear_drops, fn repo, _ ->
          {n, _} =
            from(d in TripDrop, where: d.invoice_id == ^invoice.id)
            |> repo.update_all(set: [invoice_id: nil, updated_at: now])

          {:ok, n}
        end)
        |> Multi.insert(:unlink_log, fn %{clear_drops: n} ->
          Sys.log_changeset(
            :unlink_trading_settlement,
            invoice,
            %{
              "action" => "unlink_trading_settlement",
              "invoice_no" => invoice.invoice_no,
              "drops_unlinked" => n,
              "trip_refs" => Enum.join(info.trip_refs, ", ")
            },
            company,
            user
          )
        end)
        |> Repo.transaction()
        |> case do
          {:ok, %{clear_drops: n}} -> {:ok, %{unlinked: n, kind: :customer}}
          {:error, _step, reason, _} -> {:error, reason}
        end
      end
    else
      false -> :not_authorise
      other -> other
    end
  end

  def unlink_invoice_settlement(_, _, _), do: {:error, :invalid}

  @doc """
  Clear supplier load and/or transport haul FKs for this PurInvoice.
  """
  def unlink_pur_invoice_settlement(%PurInvoice{} = pinv, company, user) do
    with :ok <- authorize_pur_invoice_update(user, company),
         true <- pinv.company_id == company.id do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      info = pur_invoice_settlement_info(pinv.id, company)

      if not info.linked? do
        {:error, :not_linked}
      else
        Multi.new()
        |> Multi.run(:clear_loads, fn repo, _ ->
          {n, _} =
            from(l in TripLoad, where: l.pur_invoice_id == ^pinv.id)
            |> repo.update_all(set: [pur_invoice_id: nil, updated_at: now])

          {:ok, n}
        end)
        |> Multi.run(:clear_transport, fn repo, _ ->
          {n, _} =
            from(d in TripDrop, where: d.transport_pur_invoice_id == ^pinv.id)
            |> repo.update_all(set: [transport_pur_invoice_id: nil, updated_at: now])

          {:ok, n}
        end)
        |> Multi.insert(:unlink_log, fn %{clear_loads: n_l, clear_transport: n_t} ->
          Sys.log_changeset(
            :unlink_trading_settlement,
            pinv,
            %{
              "action" => "unlink_trading_settlement",
              "pur_invoice_no" => pinv.pur_invoice_no,
              "loads_unlinked" => n_l,
              "transport_drops_unlinked" => n_t,
              "trip_refs" => Enum.join(info.trip_refs, ", ")
            },
            company,
            user
          )
        end)
        |> Repo.transaction()
        |> case do
          {:ok, %{clear_loads: n_l, clear_transport: n_t}} ->
            {:ok, %{loads_unlinked: n_l, transport_unlinked: n_t, kind: :purchase}}

          {:error, _step, reason, _} ->
            {:error, reason}
        end
      end
    else
      false -> :not_authorise
      other -> other
    end
  end

  def unlink_pur_invoice_settlement(_, _, _), do: {:error, :invalid}

  @doc """
  Trip-level settlement badge state for desk UI (Option C).

  Expects trip with preloaded `loads` and `drops` (invoice/pur_invoice FKs on lines).
  Only meaningful when `status == "completed"` (`show?: true`).
  """
  def trip_settlement_badges(%Trip{} = trip) do
    if trip.status != "completed" do
      %{
        show?: false,
        customer: :n_a,
        supplier: :n_a,
        transport: :n_a,
        customer_done: 0,
        customer_total: 0,
        supplier_done: 0,
        supplier_total: 0,
        transport_done: 0,
        transport_total: 0
      }
    else
      loads = List.wrap(trip.loads)
      drops = List.wrap(trip.drops)

      sales_drops = Enum.filter(drops, & &1.sales_position_id)
      commercial_loads = Enum.filter(loads, & &1.supply_position_id)

      cust_done = Enum.count(sales_drops, & &1.invoice_id)
      cust_total = length(sales_drops)

      sup_done = Enum.count(commercial_loads, & &1.pur_invoice_id)
      sup_total = length(commercial_loads)

      agent? = trip.transport_mode == "agent" and not is_nil(trip.transport_agent_id)
      haul_done = if agent?, do: Enum.count(drops, & &1.transport_pur_invoice_id), else: 0
      haul_total = if agent?, do: length(drops), else: 0

      %{
        show?: true,
        customer: stream_state(cust_done, cust_total),
        supplier: stream_state(sup_done, sup_total),
        transport: if(agent?, do: stream_state(haul_done, haul_total), else: :n_a),
        customer_done: cust_done,
        customer_total: cust_total,
        supplier_done: sup_done,
        supplier_total: sup_total,
        transport_done: haul_done,
        transport_total: haul_total
      }
    end
  end

  def trip_settlement_badges(_) do
    %{
      show?: false,
      customer: :n_a,
      supplier: :n_a,
      transport: :n_a,
      customer_done: 0,
      customer_total: 0,
      supplier_done: 0,
      supplier_total: 0,
      transport_done: 0,
      transport_total: 0
    }
  end

  defp stream_state(_done, 0), do: :n_a
  defp stream_state(0, _total), do: :open
  defp stream_state(done, total) when done >= total, do: :done
  defp stream_state(_done, _total), do: :partial

  # --- private ---

  defp authorize_view(user, company) do
    if Authorization.can?(user, :view_trading, company), do: :ok, else: :not_authorise
  end

  defp authorize_invoice(user, company) do
    if Authorization.can?(user, :create_invoice, company), do: :ok, else: :not_authorise
  end

  defp authorize_pur_invoice(user, company) do
    if Authorization.can?(user, :create_pur_invoice, company), do: :ok, else: :not_authorise
  end

  defp authorize_invoice_update(user, company) do
    if Authorization.can?(user, :update_invoice, company), do: :ok, else: :not_authorise
  end

  defp authorize_pur_invoice_update(user, company) do
    if Authorization.can?(user, :update_pur_invoice, company), do: :ok, else: :not_authorise
  end

  defp empty_settlement_info do
    %{
      linked?: false,
      line_count: 0,
      actual_mt_sum: Decimal.new(0),
      trip_refs: [],
      supplier_load_count: 0,
      transport_drop_count: 0
    }
  end

  defp build_settlement_info(rows, _kind) do
    mt =
      Enum.reduce(rows, Decimal.new(0), fn r, acc ->
        Decimal.add(acc, r.actual_mt || Decimal.new(0))
      end)

    refs =
      rows
      |> Enum.map(& &1.trip_reference_no)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    %{
      linked?: rows != [],
      line_count: length(rows),
      actual_mt_sum: mt,
      trip_refs: refs,
      supplier_load_count: 0,
      transport_drop_count: 0
    }
  end

  defp contact_id_changing?(old_id, attrs) when is_map(attrs) do
    new_id =
      Map.get(attrs, "contact_id") ||
        Map.get(attrs, :contact_id)

    cond do
      is_nil(new_id) or new_id == "" ->
        # Empty contact_id with name change is handled by validate_id; treat as change if name present
        name = Map.get(attrs, "contact_name") || Map.get(attrs, :contact_name)

        if is_binary(name) and String.trim(name) != "" do
          # contact_id not resolved yet — don't block mid-typeahead unless id explicitly different
          false
        else
          false
        end

      true ->
        to_string(new_id) != to_string(old_id)
    end
  end

  defp contact_id_changing?(_, _), do: false

  defp present_id?(id) when is_binary(id) and id != "", do: true
  defp present_id?(_), do: false

  defp maybe_filter_trip_id(q, nil), do: q
  defp maybe_filter_trip_id(q, ""), do: q

  # Second binding is always Trip (`t`) in the three settlement list queries.
  defp maybe_filter_trip_id(q, trip_id) when is_binary(trip_id) do
    where(q, [_, t], t.id == ^trip_id)
  end

  defp maybe_filter_trip_id(q, _), do: q

  # When include_settled? is true (trip deep-link), keep billed rows; otherwise hide them.
  defp maybe_require_unset_invoice(q, true), do: q
  defp maybe_require_unset_invoice(q, _), do: where(q, [d], is_nil(d.invoice_id))

  defp maybe_require_unset_pur_invoice_load(q, true), do: q
  defp maybe_require_unset_pur_invoice_load(q, _), do: where(q, [l], is_nil(l.pur_invoice_id))

  defp maybe_require_unset_transport_pur_invoice(q, true), do: q

  defp maybe_require_unset_transport_pur_invoice(q, _) do
    where(q, [d], is_nil(d.transport_pur_invoice_id))
  end

  defp maybe_filter_customer(q, nil), do: q
  defp maybe_filter_customer(q, ""), do: q

  defp maybe_filter_customer(q, customer_id) do
    from([d, t, s, c, g, l] in q, where: s.customer_id == ^customer_id)
  end

  defp maybe_filter_supplier(q, nil), do: q
  defp maybe_filter_supplier(q, ""), do: q

  defp maybe_filter_supplier(q, supplier_id) do
    from([l, t, s, c, g, loc] in q, where: s.supplier_id == ^supplier_id)
  end

  defp maybe_filter_from_date(q, nil), do: q
  defp maybe_filter_from_date(q, %Date{} = d), do: from([d0, t, s, c, g, l] in q, where: t.date >= ^d)
  defp maybe_filter_from_date(q, _), do: q

  defp maybe_filter_to_date(q, nil), do: q
  defp maybe_filter_to_date(q, %Date{} = d), do: from([d0, t, s, c, g, l] in q, where: t.date <= ^d)
  defp maybe_filter_to_date(q, _), do: q

  defp maybe_filter_load_from_date(q, nil), do: q

  defp maybe_filter_load_from_date(q, %Date{} = d) do
    from([l, t, s, c, g, loc] in q, where: t.date >= ^d)
  end

  defp maybe_filter_load_from_date(q, _), do: q

  defp maybe_filter_load_to_date(q, nil), do: q

  defp maybe_filter_load_to_date(q, %Date{} = d) do
    from([l, t, s, c, g, loc] in q, where: t.date <= ^d)
  end

  defp maybe_filter_load_to_date(q, _), do: q

  defp maybe_filter_agent(q, nil), do: q
  defp maybe_filter_agent(q, ""), do: q

  defp maybe_filter_agent(q, agent_id) do
    from([d, t, agent, g, to_loc] in q, where: t.transport_agent_id == ^agent_id)
  end

  defp maybe_filter_transport_from_date(q, nil), do: q

  defp maybe_filter_transport_from_date(q, %Date{} = d) do
    from([d0, t, agent, g, to_loc] in q, where: t.date >= ^d)
  end

  defp maybe_filter_transport_from_date(q, _), do: q

  defp maybe_filter_transport_to_date(q, nil), do: q

  defp maybe_filter_transport_to_date(q, %Date{} = d) do
    from([d0, t, agent, g, to_loc] in q, where: t.date <= ^d)
  end

  defp maybe_filter_transport_to_date(q, _), do: q

  # Origin load location for agent haul line
  defp resolve_origin(_drop, []), do: nil
  defp resolve_origin(_drop, [only]), do: only

  defp resolve_origin(%{supply_position_id: sid}, loads) when not is_nil(sid) do
    Enum.find(loads, &(&1.supply_position_id == sid)) || List.first(loads)
  end

  defp resolve_origin(_drop, loads), do: List.first(loads)

  defp load_eligible_transport_drops(drop_ids, company) do
    ids = drop_ids |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq()

    if ids == [] do
      {:error, :invalid_transport}
    else
      drops =
        from(d in TripDrop,
          join: t in Trip,
          on: t.id == d.trip_id,
          where: d.id in ^ids,
          where: t.company_id == ^company.id,
          where: t.transport_mode == "agent",
          where: not is_nil(t.transport_agent_id),
          where: t.status == "completed",
          where: is_nil(d.transport_pur_invoice_id),
          where: not is_nil(d.actual_mt),
          order_by: [asc: t.date, asc: d.seq]
        )
        |> Repo.all()
        |> Repo.preload([
          :location,
          :good,
          :supply_position,
          trip: [:transport_agent, loads: :location]
        ])

      drops =
        Enum.sort_by(drops, fn d ->
          {d.trip.date, d.trip.reference_no || "", d.seq || 0}
        end)

      if length(drops) == length(ids) do
        {:ok, drops}
      else
        {:error, :ineligible_transport}
      end
    end
  end

  defp same_agent?([first | rest]) do
    agent_id = first.trip.transport_agent_id

    if Enum.all?(rest, &(&1.trip.transport_agent_id == agent_id)) do
      :ok
    else
      {:error, :mixed_agents}
    end
  end

  defp same_agent?([]), do: {:error, :invalid_transport}

  defp pur_invoice_attrs_from_transport_drops(drops, company, user) do
    [first | _] = drops
    agent = first.trip.transport_agent

    details =
      drops
      |> Enum.with_index()
      |> Enum.map(fn {drop, idx} ->
        detail_attrs_for_transport(drop, idx, company, user)
      end)
      |> Enum.with_index()
      |> Enum.into(%{}, fn {detail, idx} -> {to_string(idx), detail} end)

    inv_date = first.trip.date || Date.utc_today()

    %{
      "pur_invoice_date" => Date.to_iso8601(inv_date),
      "due_date" => Date.to_iso8601(Date.add(inv_date, 30)),
      "load_date" => Date.to_iso8601(inv_date),
      "contact_name" => agent.name,
      "contact_id" => agent.id,
      "descriptions" => "",
      "pur_invoice_no" => "...new...",
      "pur_invoice_details" => details
    }
  end

  defp detail_attrs_for_transport(drop, idx, company, user) do
    # Line is haulage service — not the grain product that was moved
    good = ensure_haulage_good(company, user)
    hauled = drop.good && drop.good.name
    qty = drop.actual_mt
    origin = resolve_origin_struct(drop)
    from_name = origin && origin.location && origin.location.name
    to_name = drop.location && drop.location.name
    trip_ref = drop.trip.reference_no
    vehicle = drop.trip.vehicle_number
    date = drop.trip.date && Date.to_iso8601(drop.trip.date)

    desc =
      [date, vehicle, trip_ref, blank_to_nil(hauled), route_label(from_name, to_name)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    base = %{
      "quantity" => decimal_str(qty),
      # Clerk enters haulage RM from agent bill (no rate matrix in v1)
      "unit_price" => "0",
      "discount" => "0",
      "descriptions" => desc,
      "_persistent_id" => idx,
      "package_qty" => "0",
      "unit_multiplier" => "0"
    }

    if good do
      pkg = default_package(good)

      Map.merge(base, %{
        "good_id" => good.id,
        "good_name" => good.name,
        "account_name" => good.purchase_account_name,
        "account_id" => good.purchase_account_id,
        "tax_code_name" => good.purchase_tax_code_name,
        "tax_code_id" => good.purchase_tax_code_id,
        "tax_rate" => decimal_str(good.purchase_tax_rate || 0),
        "unit" => good.unit || "Mt",
        "package_name" => (pkg && pkg.name) || "",
        "package_id" => pkg && pkg.id
      })
    else
      Map.merge(base, %{
        "good_id" => nil,
        "good_name" => "Haulage",
        "account_name" => "",
        "tax_code_name" => "",
        "tax_rate" => "0",
        "package_name" => "",
        "unit" => "Mt"
      })
    end
  end

  # Resolve "Haulage" or "Transport Charges"; create "Haulage" if missing.
  defp ensure_haulage_good(company, user) do
    Enum.find_value(@haulage_good_names, fn name ->
      case Product.get_good_by_name(name, company, user) do
        %{id: id} when is_binary(id) ->
          load_good_for_invoice(id, company, user)

        _ ->
          nil
      end
    end) || create_haulage_good!(company, user)
  end

  defp create_haulage_good!(company, user) do
    sales_acct = Accounting.get_account_by_name("General Sales", company, user)
    pur_acct = Accounting.get_account_by_name("General Purchases", company, user)

    no_stax =
      Repo.one(
        from tc in TaxCode,
          where: tc.company_id == ^company.id and tc.code == "NoSTax",
          limit: 1
      )

    no_ptax =
      Repo.one(
        from tc in TaxCode,
          where: tc.company_id == ^company.id and tc.code == "NoPTax",
          limit: 1
      )

    if is_nil(sales_acct) or is_nil(pur_acct) or is_nil(no_stax) or is_nil(no_ptax) do
      nil
    else
      attrs = %{
        "name" => "Haulage",
        "unit" => "Mt",
        "category" => "Others",
        "sales_account_name" => sales_acct.name,
        "sales_account_id" => sales_acct.id,
        "purchase_account_name" => pur_acct.name,
        "purchase_account_id" => pur_acct.id,
        "sales_tax_code_name" => no_stax.code,
        "sales_tax_code_id" => no_stax.id,
        "purchase_tax_code_name" => no_ptax.code,
        "purchase_tax_code_id" => no_ptax.id,
        "packagings" => %{
          "0" => %{
            "name" => "default_pkg",
            "unit_multiplier" => "1",
            "cost_per_package" => "0",
            "default" => "true",
            "_persistent_id" => "1"
          }
        }
      }

      case StdInterface.create(Good, "good", attrs, company, user) do
        {:ok, good} ->
          load_good_for_invoice(good.id, company, user)

        _ ->
          # Race: another process created it
          case Product.get_good_by_name("Haulage", company, user) do
            %{id: id} -> load_good_for_invoice(id, company, user)
            _ -> nil
          end
      end
    end
  end

  defp resolve_origin_struct(drop) do
    loads = List.wrap(drop.trip && drop.trip.loads)

    case loads do
      [] ->
        nil

      [only] ->
        only

      many ->
        if drop.supply_position_id do
          Enum.find(many, &(&1.supply_position_id == drop.supply_position_id)) || List.first(many)
        else
          List.first(many)
        end
    end
  end

  defp route_label(from, to) do
    case {blank_to_nil(from), blank_to_nil(to)} do
      {nil, nil} -> nil
      {f, nil} -> "#{f} → ?"
      {nil, t} -> "? → #{t}"
      {f, t} -> "#{f} → #{t}"
    end
  end

  defp load_eligible_drops(drop_ids, company) do
    ids = drop_ids |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq()

    if ids == [] do
      {:error, :invalid_drops}
    else
      drops =
        from(d in TripDrop,
          join: t in Trip,
          on: t.id == d.trip_id,
          where: d.id in ^ids,
          where: t.company_id == ^company.id,
          where: t.status == "completed",
          where: is_nil(d.invoice_id),
          where: not is_nil(d.sales_position_id),
          where: not is_nil(d.actual_mt),
          order_by: [asc: t.date, asc: d.seq]
        )
        |> Repo.all()
        |> Repo.preload([:trip, :location, :good, sales_position: :customer])

      # Stable order by trip date / ref / seq after preload
      drops =
        Enum.sort_by(drops, fn d ->
          {d.trip.date, d.trip.reference_no || "", d.seq || 0}
        end)

      if length(drops) == length(ids) do
        {:ok, drops}
      else
        {:error, :ineligible_drops}
      end
    end
  end

  defp same_customer?([first | rest]) do
    customer_id = first.sales_position.customer_id

    if Enum.all?(rest, &(&1.sales_position.customer_id == customer_id)) do
      :ok
    else
      {:error, :mixed_customers}
    end
  end

  defp same_customer?([]), do: {:error, :invalid_drops}

  defp customer_matches_invoice?([first | _], invoice) do
    if first.sales_position.customer_id == invoice.contact_id do
      :ok
    else
      {:error, :customer_mismatch}
    end
  end

  defp invoice_attrs_from_drops(drops, company, user) do
    [first | _] = drops
    customer = first.sales_position.customer

    details =
      drops
      |> Enum.with_index()
      |> Enum.map(fn {drop, idx} ->
        detail_attrs_for_drop(drop, idx, company, user)
      end)
      |> Enum.with_index()
      |> Enum.into(%{}, fn {detail, idx} -> {to_string(idx), detail} end)

    invoice_date = first.trip.date || Date.utc_today()

    %{
      "invoice_date" => Date.to_iso8601(invoice_date),
      "due_date" => Date.to_iso8601(Date.add(invoice_date, 30)),
      "load_date" => Date.to_iso8601(invoice_date),
      "contact_name" => customer.name,
      "contact_id" => customer.id,
      "descriptions" => "",
      "invoice_no" => "...new...",
      "invoice_details" => details
    }
  end

  defp detail_attrs_for_drop(drop, idx, company, user) do
    sales = drop.sales_position
    good = load_good_for_invoice(drop.good_id, company, user)
    qty = drop.actual_mt
    price = sales.unit_price || Decimal.new(0)

    # DetailHelpers: if unit_multiplier > 0, quantity := package_qty * unit_multiplier.
    # Billing fixtures use multiplier 0 so quantity is taken as-is (MT actuals).
    base = %{
      "good_id" => drop.good_id,
      "quantity" => decimal_str(qty),
      "unit_price" => decimal_str(price),
      "discount" => "0",
      "descriptions" => line_description(drop),
      "_persistent_id" => idx,
      "package_qty" => "0",
      "unit_multiplier" => "0"
    }

    if good do
      pkg = default_package(good)

      Map.merge(base, %{
        "good_name" => good.name,
        "account_name" => good.sales_account_name,
        "account_id" => good.sales_account_id,
        "tax_code_name" => good.sales_tax_code_name,
        "tax_code_id" => good.sales_tax_code_id,
        "tax_rate" => decimal_str(good.sales_tax_rate || 0),
        "unit" => good.unit,
        "package_name" => (pkg && pkg.name) || "",
        "package_id" => pkg && pkg.id
      })
    else
      Map.merge(base, %{
        "good_name" => "",
        "account_name" => "",
        "tax_code_name" => "",
        "tax_rate" => "0",
        "package_name" => "",
        "unit" => ""
      })
    end
  end

  # Line description: drop date, vehicle no, sales no, location name
  defp line_description(drop) do
    date =
      case drop.trip && drop.trip.date do
        %Date{} = d -> Date.to_iso8601(d)
        _ -> nil
      end

    vehicle = drop.trip && blank_to_nil(drop.trip.vehicle_number)
    sales_no = drop.sales_position && blank_to_nil(drop.sales_position.title)
    location = drop.location && blank_to_nil(drop.location.name)

    [date, vehicle, sales_no, location]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp load_eligible_loads(load_ids, company) do
    ids = load_ids |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq()

    if ids == [] do
      {:error, :invalid_loads}
    else
      loads =
        from(l in TripLoad,
          join: t in Trip,
          on: t.id == l.trip_id,
          where: l.id in ^ids,
          where: t.company_id == ^company.id,
          where: t.status == "completed",
          where: is_nil(l.pur_invoice_id),
          where: not is_nil(l.supply_position_id),
          where: not is_nil(l.actual_mt),
          order_by: [asc: t.date, asc: l.seq]
        )
        |> Repo.all()
        |> Repo.preload([:trip, :location, :good, supply_position: :supplier])

      loads =
        Enum.sort_by(loads, fn l ->
          {l.trip.date, l.trip.reference_no || "", l.seq || 0}
        end)

      if length(loads) == length(ids) do
        {:ok, loads}
      else
        {:error, :ineligible_loads}
      end
    end
  end

  defp same_supplier?([first | rest]) do
    supplier_id = first.supply_position.supplier_id

    if Enum.all?(rest, &(&1.supply_position.supplier_id == supplier_id)) do
      :ok
    else
      {:error, :mixed_suppliers}
    end
  end

  defp same_supplier?([]), do: {:error, :invalid_loads}

  defp pur_invoice_attrs_from_loads(loads, company, user) do
    [first | _] = loads
    supplier = first.supply_position.supplier

    details =
      loads
      |> Enum.with_index()
      |> Enum.map(fn {load, idx} ->
        detail_attrs_for_load(load, idx, company, user)
      end)
      |> Enum.with_index()
      |> Enum.into(%{}, fn {detail, idx} -> {to_string(idx), detail} end)

    inv_date = first.trip.date || Date.utc_today()

    %{
      "pur_invoice_date" => Date.to_iso8601(inv_date),
      "due_date" => Date.to_iso8601(Date.add(inv_date, 30)),
      "load_date" => Date.to_iso8601(inv_date),
      "contact_name" => supplier.name,
      "contact_id" => supplier.id,
      "descriptions" => "",
      "pur_invoice_no" => "...new...",
      "pur_invoice_details" => details
    }
  end

  defp detail_attrs_for_load(load, idx, company, user) do
    supply = load.supply_position
    good = load_good_for_invoice(load.good_id, company, user)
    qty = load.actual_mt
    price = supply.unit_price || Decimal.new(0)

    base = %{
      "good_id" => load.good_id,
      "quantity" => decimal_str(qty),
      "unit_price" => decimal_str(price),
      "discount" => "0",
      "descriptions" => load_line_description(load),
      "_persistent_id" => idx,
      "package_qty" => "0",
      "unit_multiplier" => "0"
    }

    if good do
      pkg = default_package(good)

      Map.merge(base, %{
        "good_name" => good.name,
        "account_name" => good.purchase_account_name,
        "account_id" => good.purchase_account_id,
        "tax_code_name" => good.purchase_tax_code_name,
        "tax_code_id" => good.purchase_tax_code_id,
        "tax_rate" => decimal_str(good.purchase_tax_rate || 0),
        "unit" => good.unit,
        "package_name" => (pkg && pkg.name) || "",
        "package_id" => pkg && pkg.id
      })
    else
      Map.merge(base, %{
        "good_name" => "",
        "account_name" => "",
        "tax_code_name" => "",
        "tax_rate" => "0",
        "package_name" => "",
        "unit" => ""
      })
    end
  end

  # Line description: load date, vehicle no, supply no, location name
  defp load_line_description(load) do
    date =
      case load.trip && load.trip.date do
        %Date{} = d -> Date.to_iso8601(d)
        _ -> nil
      end

    vehicle = load.trip && blank_to_nil(load.trip.vehicle_number)
    supply_no = load.supply_position && blank_to_nil(load.supply_position.title)
    location = load.location && blank_to_nil(load.location.name)

    [date, vehicle, supply_no, location]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s) when is_binary(s), do: String.trim(s) |> then(fn t -> if t == "", do: nil, else: t end)
  defp blank_to_nil(other), do: to_string(other)

  defp load_good_for_invoice(good_id, company, user) when is_binary(good_id) do
    try do
      Product.get_good!(good_id, company, user)
    rescue
      Ecto.NoResultsError -> nil
    end
  end

  defp load_good_for_invoice(_, _, _), do: nil

  # Prefer good's default package; else first package by name.
  defp default_package(%{packagings: packs}) when is_list(packs) and packs != [] do
    Enum.find(packs, &(&1.default in [true, "true"])) ||
      packs
      |> Enum.sort_by(&(&1.name || ""), :asc)
      |> List.first()
  end

  defp default_package(_), do: nil

  defp decimal_str(nil), do: "0"
  defp decimal_str(%Decimal{} = d), do: Decimal.to_string(d)
  defp decimal_str(n) when is_number(n), do: to_string(n)
  defp decimal_str(s) when is_binary(s), do: s
  defp decimal_str(other), do: to_string(other)

  defp stringify_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp deep_merge_string_maps(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn
      _k, %{} = b, %{} = o -> deep_merge_string_maps(b, o)
      _k, _b, o -> o
    end)
  end
end
