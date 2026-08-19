defmodule FullCircle.XeroImport.Snapshot do
  @files ~w(
    organisation accounts tax_rates contacts items invoices credit_notes
    bank_transactions payments manual_journals bank_transfers
    fixed_assets conversion_balances reports
  )a

  @pull_steps [
    {:organisation, :get_organisation},
    {:accounts, :list_accounts},
    {:tax_rates, :list_tax_rates},
    {:contacts, :list_contacts},
    {:items, :list_items},
    {:invoices, :list_invoices},
    {:credit_notes, :list_credit_notes},
    {:bank_transactions, :list_bank_transactions},
    {:payments, :list_payments},
    {:manual_journals, :list_manual_journals},
    {:bank_transfers, :list_bank_transfers},
    {:fixed_assets, :list_fixed_assets},
    {:conversion_balances, :get_conversion_balances},
    {:reports, :get_reports}
  ]

  def read(dir) do
    Enum.reduce_while(@files, {:ok, %{}}, fn key, {:ok, acc} ->
      path = Path.join(dir, "#{key}.json")

      cond do
        not File.exists?(path) ->
          {:halt, {:error, {:missing_file, path}}}

        true ->
          with {:ok, bin} <- File.read(path),
               {:ok, json} <- Jason.decode(bin) do
            {:cont, {:ok, Map.put(acc, key, json)}}
          else
            err -> {:halt, {:error, err}}
          end
      end
    end)
  end

  def pull(%mod{} = client, dest_dir) do
    tmp = dest_dir <> ".tmp"
    File.rm_rf(tmp)
    File.mkdir_p!(tmp)

    result =
      Enum.reduce_while(@pull_steps, {:ok, %{}}, fn {key, fun}, {:ok, acc} ->
        case apply(mod, fun, [client]) do
          {:ok, data} -> {:cont, {:ok, Map.put(acc, key, data)}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    result =
      with {:ok, data} <- result,
           {:ok, data} <- pull_yearly_trial_balances(client, data) do
        {:ok, data}
      end

    case result do
      {:ok, data} ->
        data = finalize(data)
        write_files!(tmp, data)

        case swap_dir(tmp, dest_dir) do
          :ok ->
            {:ok, dest_dir}

          {:error, reason} ->
            File.rm_rf(tmp)
            {:error, reason}
        end

      {:error, _} = err ->
        File.rm_rf(tmp)
        err
    end
  end

  def pull(mod, dest_dir) when is_atom(mod), do: pull(struct(mod), dest_dir)

  # Xero's TB report is YTD-based, so multi-year catch-up (payroll and other
  # system journals that no readable API exposes) needs a TB per financial
  # year end. The current-date TB is appended as the final period.
  defp pull_yearly_trial_balances(%mod{} = client, data) do
    today = Date.utc_today()

    yearly =
      data
      |> fye_dates(today)
      |> Enum.reduce_while({:ok, []}, fn date, {:ok, acc} ->
        case apply(mod, :get_trial_balance, [client, date]) do
          {:ok, lines} ->
            {:cont, {:ok, acc ++ [%{"date" => Date.to_iso8601(date), "lines" => lines}]}}

          {:error, _} = err ->
            {:halt, err}
        end
      end)

    with {:ok, periods} <- yearly do
      current = %{
        "date" => Date.to_iso8601(today),
        "lines" => (is_map(data.reports) && data.reports["trial_balance"]) || []
      }

      reports =
        (is_map(data.reports) && data.reports)
        |> Kernel.||(%{})
        |> Map.put("trial_balance_by_year", periods ++ [current])

      {:ok, Map.put(data, :reports, reports)}
    end
  end

  defp fye_dates(data, today) do
    org = data[:organisation] || %{}
    month = org["FinancialYearEndMonth"] || 12
    day = org["FinancialYearEndDay"] || 31

    case earliest_doc_year(data) do
      nil ->
        []

      first_year ->
        for year <- first_year..today.year,
            {:ok, date} <- [fye_for(year, month, day)],
            Date.compare(date, today) == :lt do
          date
        end
    end
  end

  defp fye_for(year, month, day) do
    Date.new(year, month, min(day, Date.days_in_month(Date.new!(year, month, 1))))
  end

  defp earliest_doc_year(data) do
    [:invoices, :bank_transactions, :manual_journals, :payments]
    |> Enum.flat_map(fn key -> data |> Map.get(key) |> List.wrap() end)
    |> Enum.map(&doc_year(&1["DateString"] || &1["Date"]))
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> nil end)
  end

  defp doc_year("/Date(" <> rest) do
    case Integer.parse(rest) do
      {ms, _} -> ms |> DateTime.from_unix!(:millisecond) |> Map.fetch!(:year)
      :error -> nil
    end
  end

  defp doc_year(<<y::binary-size(4), "-", _::binary>>) do
    case Integer.parse(y) do
      {year, ""} -> year
      _ -> nil
    end
  end

  defp doc_year(_), do: nil

  defp write_files!(dir, data) do
    Enum.each(@files, fn key ->
      path = Path.join(dir, "#{key}.json")
      File.write!(path, Jason.encode!(Map.fetch!(data, key), pretty: true))
    end)
  end

  defp swap_dir(tmp, dest) do
    old = dest <> ".old"

    if File.exists?(dest) do
      File.rm_rf(old)

      with :ok <- File.rename(dest, old),
           :ok <- File.rename(tmp, dest) do
        File.rm_rf(old)
        :ok
      else
        {:error, reason} ->
          if File.exists?(old) and not File.exists?(dest) do
            _ = File.rename(old, dest)
          end

          {:error, reason}
      end
    else
      File.rename(tmp, dest)
    end
  end

  defp finalize(data) do
    data
    |> remap_conversion()
    |> fill_reports()
  end

  defp remap_conversion(%{accounts: accounts, conversion_balances: cb} = data) when is_map(cb) do
    by_code =
      accounts
      |> List.wrap()
      |> Enum.reduce(%{}, fn
        %{"Code" => code} = acc, map when is_binary(code) ->
          id = acc["AccountID"] || acc["AccountId"]
          if id, do: Map.put(map, code, id), else: map

        _, map ->
          map
      end)

    lines =
      Enum.map(cb["Lines"] || [], fn line ->
        id = line["AccountID"] || line["AccountId"] || by_code[line["AccountCode"]]
        if id, do: Map.put(line, "AccountID", id), else: line
      end)

    Map.put(data, :conversion_balances, Map.put(cb, "Lines", lines))
  end

  defp remap_conversion(data), do: data

  defp fill_reports(%{reports: reports} = data) when is_map(reports) do
    reports =
      reports
      |> Map.put_new("invoice_totals", doc_totals(Map.get(data, :invoices), "ACCREC"))
      |> Map.put_new("bill_totals", doc_totals(Map.get(data, :invoices), "ACCPAY"))
      |> Map.put_new("fa_nbv", fa_nbv(Map.get(data, :fixed_assets)))
      |> Map.put_new("bank", bank_lines(reports, Map.get(data, :accounts)))
      |> fill_aged("aged_receivables", Map.get(data, :contacts), :ar)
      |> fill_aged("aged_payables", Map.get(data, :contacts), :ap)

    Map.put(data, :reports, reports)
  end

  defp fill_reports(data), do: data

  defp doc_totals(rows, type) do
    # Zero-total docs are skipped by the import (FC requires amount > 0),
    # so exclude them here to keep the reconcile counts consistent.
    docs =
      rows
      |> List.wrap()
      |> Enum.filter(fn row ->
        row["Type"] == type and row["Status"] in ["AUTHORISED", "PAID"] and
          to_float(row["Total"]) != 0.0
      end)

    amount =
      Enum.reduce(docs, 0.0, fn row, acc ->
        acc + to_float(row["Total"])
      end)

    %{"count" => length(docs), "amount" => amount}
  end

  defp fa_nbv(assets) do
    assets
    |> List.wrap()
    |> Enum.map(fn asset ->
      %{
        "name" => asset["AssetName"] || asset["AssetNumber"],
        "nbv" => asset["BookValue"] || asset["AccountingBookValue"] || 0
      }
    end)
  end

  defp fill_aged(reports, key, contacts, kind) do
    case reports[key] do
      list when is_list(list) and list != [] ->
        reports

      _ ->
        Map.put(reports, key, aged_from_contacts(contacts, kind))
    end
  end

  defp aged_from_contacts(contacts, kind) do
    sign = if kind == :ap, do: -1, else: 1
    path =
      if kind == :ap do
        ["Balances", "AccountsPayable", "Outstanding"]
      else
        ["Balances", "AccountsReceivable", "Outstanding"]
      end

    alt_path =
      if kind == :ap do
        ["balances", "accountsPayable", "outstanding"]
      else
        ["balances", "accountsReceivable", "outstanding"]
      end

    contacts
    |> List.wrap()
    |> Enum.flat_map(fn contact ->
      bal = get_in(contact, path) || get_in(contact, alt_path) || 0
      amount = to_float(bal)

      if amount == 0.0 do
        []
      else
        [
          %{
            "contact_name" => contact["Name"] || contact["name"],
            "balance" => sign * amount
          }
        ]
      end
    end)
  end

  defp bank_lines(reports, accounts) do
    bank_names =
      accounts
      |> List.wrap()
      |> Enum.filter(&(&1["Type"] == "BANK"))
      |> MapSet.new(& &1["Name"])

    if MapSet.size(bank_names) == 0 do
      []
    else
      # TB report names carry " (Code)" suffixes; strip before matching.
      Enum.filter(reports["trial_balance"] || [], fn line ->
        name = String.replace(line["account_name"] || "", ~r/ \([^()]*\)$/, "")
        MapSet.member?(bank_names, name)
      end)
    end
  end

  defp to_float(n) when is_integer(n), do: n * 1.0
  defp to_float(n) when is_float(n), do: n

  defp to_float(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp to_float(_), do: 0.0
end
