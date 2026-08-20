defmodule FullCircle.XeroImport.Reconcile do
  import Ecto.Query, warn: false

  alias FullCircle.Accounting.{
    Account,
    Contact,
    FixedAsset,
    FixedAssetDepreciation,
    FixedAssetDisposal,
    Transaction
  }

  alias FullCircle.Billing.{Invoice, InvoiceDetail, PurInvoice, PurInvoiceDetail}
  alias FullCircle.Repo
  alias FullCircle.XeroImport.Mapper

  @tolerance Decimal.new("0.01")

  def run(snapshot, company, user, opts \\ [])

  def run(snapshot, company, _user, opts) do
    reports = snapshot.reports || %{}
    overrides = Keyword.get(opts, :overrides) || %{}

    checks = [
      check_trial_balance(reports, company, overrides),
      check_named(
        :aged_receivables,
        report_lines(reports, "aged_receivables"),
        live_aged(company, "Account Receivables")
      ),
      check_named(
        :aged_payables,
        report_lines(reports, "aged_payables"),
        live_aged(company, "Account Payables")
      ),
      check_totals(
        :invoice_totals,
        report_totals(reports, "invoice_totals"),
        live_invoice_totals(company)
      ),
      check_totals(
        :bill_totals,
        report_totals(reports, "bill_totals"),
        live_bill_totals(company)
      ),
      check_named(:fa_nbv, report_lines(reports, "fa_nbv"), live_fa_nbv(company)),
      check_named(:bank, report_lines(reports, "bank"), live_bank(company), overrides)
    ]

    result = %{checks: checks}

    if Enum.all?(checks, & &1.ok?) do
      {:ok, result}
    else
      {:error, result}
    end
  end

  @fc_pl_types ["Revenue", "Other Income", "Direct Costs", "Expenses", "Overhead", "Depreciation"]

  # Xero's TB report shows P&L accounts as current-FY YTD plus a computed
  # Retained Earnings line, while FC holds the full history — so P&L (with
  # Retained Earnings) can only be reconciled in aggregate. Balance-sheet
  # accounts compare per-account.
  defp check_trial_balance(reports, company, overrides) do
    rows = report_lines(reports, "trial_balance")
    re_name = Mapper.control_account_name("Retained Earnings", overrides)

    live =
      from(t in Transaction,
        join: a in Account,
        on: a.id == t.account_id,
        where: t.company_id == ^company.id,
        group_by: [a.name, a.account_type],
        select: {a.name, a.account_type, sum(t.amount)}
      )
      |> Repo.all()

    {live_bs, live_pl} =
      Enum.reduce(live, {%{}, Decimal.new(0)}, fn {name, type, amt}, {bs, pl} ->
        amt = decimalize(amt)

        if type in @fc_pl_types or name == re_name do
          {bs, Decimal.add(pl, amt)}
        else
          {Map.put(bs, name, amt), pl}
        end
      end)

    pl_names =
      for {name, type, _} <- live, type in @fc_pl_types, into: MapSet.new([re_name]) do
        name
      end

    {bs_rows, expected_pl} =
      Enum.reduce(rows, {[], Decimal.new(0)}, fn row, {acc, pl} ->
        key = remap_expected_name(line_key(row), :trial_balance, overrides)
        amt = decimalize(line_amount(row))

        if MapSet.member?(pl_names, key) do
          {acc, Decimal.add(pl, amt)}
        else
          {[%{"account_name" => key, "balance" => amt} | acc], pl}
        end
      end)

    check = check_named(:trial_balance, Enum.reverse(bs_rows), live_bs, overrides)
    pl_delta = Decimal.sub(live_pl, expected_pl)

    if within_tolerance?(pl_delta) do
      check
    else
      diff = %{
        key: "P&L + Retained Earnings",
        account_name: "P&L + Retained Earnings",
        xero: expected_pl,
        full_circle: live_pl,
        delta: pl_delta
      }

      %{check | ok?: false, diffs: check.diffs ++ [diff]}
    end
  end

  defp live_bank(company) do
    from(t in Transaction,
      join: a in Account,
      on: a.id == t.account_id,
      where: t.company_id == ^company.id,
      where: a.account_type == "Bank",
      group_by: a.name,
      select: {a.name, sum(t.amount)}
    )
    |> Repo.all()
    |> Map.new(fn {name, amt} -> {name, decimalize(amt)} end)
  end

  # Xero's per-contact Outstanding nets everything hitting the control account
  # (invoices, credit notes, unallocated receipts), so mirror it as a plain
  # contact-grouped sum of control-account transactions — matchers are aging
  # metadata, not balance.
  defp live_aged(company, control_account_name) do
    from(t in Transaction,
      join: a in Account,
      on: a.id == t.account_id,
      join: c in Contact,
      on: c.id == t.contact_id,
      where: t.company_id == ^company.id,
      where: a.name == ^control_account_name,
      group_by: c.name,
      select: {c.name, sum(t.amount)}
    )
    |> Repo.all()
    |> Map.new(fn {name, amt} -> {name, decimalize(amt)} end)
  end

  defp live_invoice_totals(company) do
    {count, amount} =
      Repo.one(
        from i in Invoice,
          left_join: d in InvoiceDetail,
          on: d.invoice_id == i.id,
          where: i.company_id == ^company.id,
          select:
            {count(i.id, :distinct),
             coalesce(
               sum(
                 fragment(
                   "(? * ? + ?) * (1 + ?)",
                   d.quantity,
                   d.unit_price,
                   d.discount,
                   d.tax_rate
                 )
               ),
               0
             )}
      ) || {0, Decimal.new(0)}

    %{count: count, amount: decimalize(amount)}
  end

  defp live_bill_totals(company) do
    {count, amount} =
      Repo.one(
        from i in PurInvoice,
          left_join: d in PurInvoiceDetail,
          on: d.pur_invoice_id == i.id,
          where: i.company_id == ^company.id,
          select:
            {count(i.id, :distinct),
             coalesce(
               sum(
                 fragment(
                   "(? * ? + ?) * (1 + ?)",
                   d.quantity,
                   d.unit_price,
                   d.discount,
                   d.tax_rate
                 )
               ),
               0
             )}
      ) || {0, Decimal.new(0)}

    %{count: count, amount: decimalize(amount)}
  end

  defp live_fa_nbv(company) do
    assets =
      from(fa in FixedAsset,
        where: fa.company_id == ^company.id,
        select: {fa.id, fa.name, fa.pur_price}
      )
      |> Repo.all()

    ids = Enum.map(assets, &elem(&1, 0))

    depre =
      if ids == [] do
        %{}
      else
        from(d in FixedAssetDepreciation,
          where: d.fixed_asset_id in ^ids,
          where: d.is_seed == true,
          group_by: d.fixed_asset_id,
          select: {d.fixed_asset_id, sum(d.amount)}
        )
        |> Repo.all()
        |> Map.new(fn {id, amt} -> {id, decimalize(amt)} end)
      end

    disposals =
      if ids == [] do
        %{}
      else
        from(d in FixedAssetDisposal,
          where: d.fixed_asset_id in ^ids,
          group_by: d.fixed_asset_id,
          select: {d.fixed_asset_id, sum(d.amount)}
        )
        |> Repo.all()
        |> Map.new(fn {id, amt} -> {id, decimalize(amt)} end)
      end

    # Same-named Xero assets import with " (2)" suffixes; the expected side
    # keys by the original name, so group live NBV by the base name.
    Enum.reduce(assets, %{}, fn {id, name, pur_price}, acc ->
      nbv =
        pur_price
        |> decimalize()
        |> Decimal.sub(Map.get(depre, id, Decimal.new(0)))
        |> Decimal.sub(Map.get(disposals, id, Decimal.new(0)))

      base = String.replace(name, ~r/ \(\d+\)$/, "")
      Map.update(acc, base, nbv, &Decimal.add(&1, nbv))
    end)
  end

  defp check_named(name, expected_rows, live_map, overrides \\ %{}) do
    expected_map =
      Enum.reduce(expected_rows, %{}, fn row, acc ->
        key = remap_expected_name(line_key(row), name, overrides)
        amt = decimalize(line_amount(row))
        Map.update(acc, key, amt, &Decimal.add(&1, amt))
      end)

    keys =
      expected_map
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.union(nonzero_keys(live_map))
      |> Enum.sort()

    diffs =
      Enum.reduce(keys, [], fn key, acc ->
        xero = Map.get(expected_map, key, Decimal.new(0))
        fc = Map.get(live_map, key, Decimal.new(0))
        delta = Decimal.sub(fc, xero)

        if within_tolerance?(delta) do
          acc
        else
          [named_diff(name, key, xero, fc, delta) | acc]
        end
      end)
      |> Enum.reverse()

    %{name: name, ok?: diffs == [], diffs: diffs}
  end

  defp check_totals(name, expected, live) do
    diffs =
      []
      |> maybe_total_diff("count", expected.count, live.count)
      |> maybe_total_diff("amount", expected.amount, live.amount)

    %{name: name, ok?: diffs == [], diffs: diffs}
  end

  defp maybe_total_diff(diffs, key, expected, live) when key == "count" do
    xero = expected || 0
    fc = live || 0
    delta = fc - xero

    if delta == 0 do
      diffs
    else
      diffs ++
        [
          %{
            key: key,
            xero: xero,
            full_circle: fc,
            delta: delta
          }
        ]
    end
  end

  defp maybe_total_diff(diffs, key, expected, live) do
    xero = decimalize(expected)
    fc = decimalize(live)
    delta = Decimal.sub(fc, xero)

    if within_tolerance?(delta) do
      diffs
    else
      diffs ++
        [
          %{
            key: key,
            xero: xero,
            full_circle: fc,
            delta: delta
          }
        ]
    end
  end

  defp named_diff(name, key, xero, fc, delta) do
    label =
      case name do
        :trial_balance -> :account_name
        :bank -> :account_name
        :aged_receivables -> :contact_name
        :aged_payables -> :contact_name
        :fa_nbv -> :name
        _ -> :key
      end

    %{
      :key => key,
      label => key,
      :xero => xero,
      :full_circle => fc,
      :delta => delta
    }
  end

  defp nonzero_keys(map) do
    map
    |> Enum.filter(fn {_k, v} -> not Decimal.eq?(decimalize(v), 0) end)
    |> Enum.map(&elem(&1, 0))
    |> MapSet.new()
  end

  defp within_tolerance?(delta) do
    Decimal.compare(Decimal.abs(decimalize(delta)), @tolerance) == :lt
  end

  defp report_lines(reports, key) do
    case Map.get(reports, key) || Map.get(reports, String.to_atom(key)) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp report_totals(reports, key) do
    case Map.get(reports, key) || Map.get(reports, String.to_atom(key)) do
      %{} = map ->
        %{
          count: map["count"] || map[:count] || 0,
          amount: decimalize(map["amount"] || map[:amount] || 0)
        }

      _ ->
        %{count: 0, amount: Decimal.new(0)}
    end
  end

  defp remap_expected_name(key, name, overrides)
       when name in [:trial_balance, :bank] and is_binary(key) do
    key
    |> Mapper.strip_code_suffix()
    |> Mapper.control_account_name(overrides)
  end

  defp remap_expected_name(key, _name, _overrides), do: key

  defp line_key(row) when is_map(row) do
    row["account_name"] || row[:account_name] ||
      row["contact_name"] || row[:contact_name] ||
      row["name"] || row[:name] ||
      row["key"] || row[:key]
  end

  defp line_amount(row) when is_map(row) do
    row["balance"] || row[:balance] ||
      row["nbv"] || row[:nbv] ||
      row["amount"] || row[:amount] ||
      0
  end

  defp decimalize(%Decimal{} = d), do: Decimal.round(d, 2)
  defp decimalize(n) when is_integer(n), do: Decimal.new(n) |> Decimal.round(2)
  defp decimalize(n) when is_float(n), do: n |> Decimal.from_float() |> Decimal.round(2)

  defp decimalize(n) when is_binary(n) do
    case Decimal.parse(n) do
      {d, _} -> Decimal.round(d, 2)
      :error -> Decimal.new(0)
    end
  end

  defp decimalize(nil), do: Decimal.new(0)
  defp decimalize(_), do: Decimal.new(0)
end
