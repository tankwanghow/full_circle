defmodule FullCircle.Trading.Settlement do
  @moduledoc """
  Trading desk settlement (Phase A: customer invoicing from completed drops).

  Trading remains logistics truth; Invoice remains AR/GL truth.
  Eligibility gate: trip `status == "completed"` only.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias FullCircle.Repo
  alias FullCircle.Authorization
  alias FullCircle.Product
  alias FullCircle.Billing
  alias FullCircle.Accounting.Contact
  alias FullCircle.Product.Good
  alias FullCircle.Trading.{Trip, TripDrop, SalesPosition, Location}

  @doc """
  Sales drops for the customer-invoicing board.

  Includes:
  - **draft / planned** trips (visible, not selectable)
  - **completed** trips not yet linked to an invoice (selectable when `actual_mt` present)

  Cancelled trips and already-invoiced drops are excluded.

  Each row has `invoiceable: true | false`. Only invoiceable rows may be billed.

  Options:
  - `:customer_id` — filter by sales customer
  - `:from_date` / `:to_date` — trip date range
  """
  def list_uninvoiced_drops(company, user, opts \\ []) do
    if Authorization.can?(user, :view_trading, company) do
      customer_id = Keyword.get(opts, :customer_id)
      from_date = Keyword.get(opts, :from_date)
      to_date = Keyword.get(opts, :to_date)

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
        where: t.company_id == ^company.id,
        where: t.status in ["draft", "planned", "completed"],
        where: is_nil(d.invoice_id),
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
          invoiceable:
            t.status == "completed" and not is_nil(d.actual_mt)
        }
      )
      |> maybe_filter_customer(customer_id)
      |> maybe_filter_from_date(from_date)
      |> maybe_filter_to_date(to_date)
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

  # --- private ---

  defp authorize_view(user, company) do
    if Authorization.can?(user, :view_trading, company), do: :ok, else: :not_authorise
  end

  defp authorize_invoice(user, company) do
    if Authorization.can?(user, :create_invoice, company), do: :ok, else: :not_authorise
  end

  defp maybe_filter_customer(q, nil), do: q
  defp maybe_filter_customer(q, ""), do: q

  defp maybe_filter_customer(q, customer_id) do
    from([d, t, s, c, g, l] in q, where: s.customer_id == ^customer_id)
  end

  defp maybe_filter_from_date(q, nil), do: q
  defp maybe_filter_from_date(q, %Date{} = d), do: from([d0, t, s, c, g, l] in q, where: t.date >= ^d)
  defp maybe_filter_from_date(q, _), do: q

  defp maybe_filter_to_date(q, nil), do: q
  defp maybe_filter_to_date(q, %Date{} = d), do: from([d0, t, s, c, g, l] in q, where: t.date <= ^d)
  defp maybe_filter_to_date(q, _), do: q

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

  defp default_package(%{packagings: packs}) when is_list(packs) do
    Enum.find(packs, & &1.default) || List.first(packs)
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
