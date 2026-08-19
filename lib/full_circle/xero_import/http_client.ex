defmodule FullCircle.XeroImport.HttpClient do
  @moduledoc false

  @behaviour FullCircle.XeroImport.Client

  alias FullCircle.XeroImport.Credentials

  @accounting "https://api.xero.com/api.xro/2.0"
  @assets "https://api.xero.com/assets.xro/1.0"
  @connections "https://api.xero.com/connections"
  @max_attempts 5

  defstruct [:token_agent, :tenant_id, :credentials, :req_options, :sleeper]

  def new(opts) do
    token = Keyword.fetch!(opts, :access_token)
    credentials = Keyword.get(opts, :credentials)
    {:ok, pid} = Agent.start_link(fn -> %{token: token, credentials: credentials} end)

    %__MODULE__{
      token_agent: pid,
      tenant_id: Keyword.fetch!(opts, :tenant_id),
      credentials: credentials,
      req_options: Keyword.get(opts, :req_options, []),
      sleeper: Keyword.get(opts, :sleeper, &Process.sleep/1)
    }
  end

  @impl true
  def get_organisation(client) do
    with {:ok, body} <- request(client, :get, "#{@accounting}/Organisation") do
      {:ok, first_of(body, "Organisations")}
    end
  end

  @impl true
  def list_accounts(client), do: get_all(client, "#{@accounting}/Accounts", "Accounts")

  @impl true
  def list_tax_rates(client), do: get_all(client, "#{@accounting}/TaxRates", "TaxRates")

  @impl true
  def list_contacts(client) do
    # Archived contacts still own historical invoices; without them the
    # replay aborts on an unmapped contact.
    get_pages(client, "#{@accounting}/Contacts", "Contacts", 1, [], includeArchived: true)
  end

  @impl true
  def list_items(client), do: get_pages(client, "#{@accounting}/Items", "Items")

  @impl true
  def list_invoices(client), do: get_pages(client, "#{@accounting}/Invoices", "Invoices")

  @impl true
  def list_credit_notes(client),
    do: get_pages(client, "#{@accounting}/CreditNotes", "CreditNotes")

  @impl true
  def list_payments(client), do: get_pages(client, "#{@accounting}/Payments", "Payments")

  @impl true
  def list_bank_transactions(client),
    do: get_pages(client, "#{@accounting}/BankTransactions", "BankTransactions")

  @impl true
  def list_bank_transfers(client),
    do: get_pages(client, "#{@accounting}/BankTransfers", "BankTransfers")

  @impl true
  def list_manual_journals(client),
    do: get_pages(client, "#{@accounting}/ManualJournals", "ManualJournals")

  @asset_statuses ~w(REGISTERED DISPOSED)
  @asset_page_size 200

  @impl true
  def list_fixed_assets(client) do
    types_by_id =
      case request(client, :get, "#{@assets}/AssetTypes") do
        {:ok, body} ->
          body
          |> extract_list("items")
          |> then(fn
            [] -> extract_list(body, "AssetTypes")
            list -> list
          end)
          |> Map.new(fn type ->
            id = type["assetTypeId"] || type["AssetTypeId"]
            {to_string(id), type}
          end)

        {:error, _} ->
          %{}
      end

    Enum.reduce_while(@asset_statuses, {:ok, []}, fn status, {:ok, acc} ->
      case list_assets_by_status(client, status) do
        {:ok, items} -> {:cont, {:ok, acc ++ items}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, items} -> hydrate_assets(client, items, types_by_id)
      {:error, _} = err -> err
    end
  end

  @impl true
  def get_conversion_balances(client) do
    with {:ok, body} <- request(client, :get, "#{@accounting}/Setup") do
      {:ok, normalize_setup(body)}
    end
  end

  @impl true
  def get_reports(client) do
    # AgedReceivablesByContact / AgedPayablesByContact require contactID and 400
    # without it. Snapshot.pull fills aged from Contacts Outstanding instead.
    with {:ok, tb} <- request(client, :get, "#{@accounting}/Reports/TrialBalance") do
      {:ok,
       %{
         "trial_balance" => parse_trial_balance(tb),
         "aged_receivables" => [],
         "aged_payables" => []
       }}
    end
  end

  def fetch_tenants(access_token, opts \\ []) do
    req_opts =
      [
        headers: [
          {"authorization", "Bearer #{access_token}"},
          {"accept", "application/json"}
        ],
        retry: false
      ]
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    case Req.get(@connections, req_opts) do
      {:ok, %{status: 200, body: list}} when is_list(list) -> {:ok, list}
      {:ok, %{status: 200, body: body}} -> {:ok, List.wrap(body)}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  def pick_tenant(tenants, preferred_name) do
    match = Enum.find(tenants, fn t -> t["tenantName"] == preferred_name end)

    case match || List.first(tenants) do
      %{"tenantId" => id} when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :no_tenant}
    end
  end

  defp get_all(client, url, key) do
    with {:ok, body} <- request(client, :get, url) do
      {:ok, extract_list(body, key)}
    end
  end

  defp get_pages(client, url, key, page \\ 1, acc \\ [], extra_params \\ []) do
    with {:ok, body} <- request(client, :get, url, params: extra_params ++ [page: page]) do
      items = extract_list(body, key)

      cond do
        items == [] ->
          {:ok, acc}

        page > 1 and repeated_page?(items, acc) ->
          {:ok, acc}

        page >= 10_000 ->
          {:ok, acc ++ items}

        true ->
          get_pages(client, url, key, page + 1, acc ++ items, extra_params)
      end
    end
  end

  defp repeated_page?([head | _], acc), do: Enum.any?(acc, &(&1 == head))
  defp repeated_page?(_, _), do: false

  defp request(client, method, url, opts \\ []) do
    request_loop(client, method, url, opts, 1, false)
  end

  defp request_loop(client, method, url, opts, attempt, refreshed) do
    token = Agent.get(client.token_agent, & &1.token)

    headers = [
      {"authorization", "Bearer #{token}"},
      {"xero-tenant-id", to_string(client.tenant_id)},
      {"accept", "application/json"}
    ]

    req_opts =
      [method: method, url: url, headers: headers, retry: false]
      |> Keyword.merge(client.req_options)
      |> Keyword.merge(opts)
      |> Keyword.put(:retry, false)

    case Req.request(req_opts) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, decode(body)}

      {:ok, %{status: 429} = resp} when attempt < @max_attempts ->
        client.sleeper.(retry_delay_ms(resp, attempt))
        request_loop(client, method, url, opts, attempt + 1, refreshed)

      {:ok, %{status: 429}} ->
        {:error, :too_many_requests}

      {:ok, %{status: 401}} when not refreshed ->
        case refresh_token(client) do
          {:ok, _} -> request_loop(client, method, url, opts, attempt, true)
          {:error, _} = err -> err
        end

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp refresh_token(client) do
    creds = Agent.get(client.token_agent, & &1.credentials)

    if is_nil(creds) do
      {:error, :unauthorized}
    else
      case Credentials.token(creds, req_options: client.req_options) do
        {:ok, %{access_token: token} = tokens} ->
          # Xero refresh tokens are single-use: keep the rotated one in memory
          # for the next refresh and persist it right away, or a later failure
          # leaves a consumed token on disk and bricks subsequent runs.
          creds = rotate_credentials(creds, tokens)
          Agent.update(client.token_agent, fn _ -> %{token: token, credentials: creds} end)
          {:ok, client}

        {:error, _} = err ->
          err
      end
    end
  end

  defp rotate_credentials(creds, tokens) do
    refresh = tokens[:refresh_token]

    if is_binary(refresh) and refresh != "" do
      path = creds[:path]

      if is_binary(path) do
        _ = Credentials.append_tokens(path, tokens)
      end

      Map.put(creds, :refresh_token, refresh)
    else
      creds
    end
  end

  defp retry_delay_ms(resp, attempt) do
    case Req.Response.get_header(resp, "retry-after") do
      [val | _] ->
        case Integer.parse(to_string(val)) do
          {n, _} -> n * 1000
          :error -> backoff_ms(attempt)
        end

      _ ->
        backoff_ms(attempt)
    end
  end

  defp backoff_ms(attempt) do
    seconds = min(8, 2 * Integer.pow(2, attempt - 1))
    seconds * 1000
  end

  defp first_of(body, key) when is_map(body) do
    case body[key] do
      [first | _] -> first
      %{} = map -> map
      _ -> body
    end
  end

  defp first_of(body, _key), do: body

  defp extract_list(body, key) when is_map(body) do
    case body[key] do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp extract_list(list, _key) when is_list(list), do: list
  defp extract_list(_, _), do: []

  defp decode(body) when is_map(body) or is_list(body), do: body

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp decode(body), do: body

  defp normalize_setup(body) do
    setup = if is_map(body), do: body["Setup"] || body, else: %{}
    date = conversion_date(setup["ConversionDate"] || (is_map(body) && body["ConversionDate"]))
    balances = setup["ConversionBalances"] || (is_map(body) && body["ConversionBalances"]) || []

    lines =
      Enum.map(List.wrap(balances), fn row ->
        %{
          "AccountID" => row["AccountID"] || row["AccountId"],
          "AccountCode" => row["AccountCode"],
          "Balance" => row["Balance"]
        }
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()
      end)

    %{"Date" => date, "Lines" => lines}
  end

  defp conversion_date(%{"Year" => year, "Month" => month} = map) do
    day = Map.get(map, "Day") || 1

    "#{pad_int(year, 4)}-#{pad_int(month, 2)}-#{pad_int(day, 2)}"
  end

  defp conversion_date(other) when is_binary(other), do: other
  defp conversion_date(_), do: nil

  defp pad_int(n, width), do: n |> to_string() |> String.pad_leading(width, "0")

  defp parse_trial_balance(body) do
    rows = report_rows(body)
    cols = tb_amount_columns(rows)

    rows
    |> walk_detail_rows()
    |> Enum.flat_map(&tb_line(&1, cols))
  end

  # Xero's TrialBalance report carries [Account, Debit, Credit, YTD Debit,
  # YTD Credit]; the YTD columns are the balances. Cells must be read by
  # position — blanks are real cells, not gaps to be filtered out.
  defp tb_amount_columns(rows) do
    header =
      Enum.find(List.wrap(rows), fn
        %{"RowType" => "Header"} -> true
        _ -> false
      end)

    titles =
      ((header && header["Cells"]) || [])
      |> Enum.map(fn cell -> cell |> cell_value() |> to_string() |> String.downcase() end)

    cond do
      "ytd debit" in titles ->
        {Enum.find_index(titles, &(&1 == "ytd debit")),
         Enum.find_index(titles, &(&1 == "ytd credit"))}

      "debit" in titles ->
        {Enum.find_index(titles, &(&1 == "debit")), Enum.find_index(titles, &(&1 == "credit"))}

      true ->
        nil
    end
  end

  defp report_rows(%{"Reports" => [report | _]}), do: report["Rows"] || []
  defp report_rows(%{"Rows" => rows}) when is_list(rows), do: rows
  defp report_rows(_), do: []

  defp walk_detail_rows(rows) when is_list(rows) do
    Enum.flat_map(rows, fn
      %{"RowType" => type, "Rows" => inner} when type in ["Section", "Row"] and is_list(inner) ->
        walk_detail_rows(inner)

      %{"RowType" => "Row"} = row ->
        [row]

      _ ->
        []
    end)
  end

  defp walk_detail_rows(_), do: []

  defp tb_line(%{"Cells" => cells}, cols) do
    values = Enum.map(cells || [], &cell_value/1)
    name = List.first(values)

    {di, ci} =
      case cols do
        {di, ci} when is_integer(di) and is_integer(ci) -> {di, ci}
        _ -> {length(values) - 2, length(values) - 1}
      end

    cond do
      not is_binary(name) or name == "" or name in ["Total", "Opening Balances"] ->
        []

      true ->
        debit = number_at(values, di)
        credit = number_at(values, ci)
        [%{"account_name" => name, "balance" => debit - credit}]
    end
  end

  defp tb_line(_, _cols), do: []

  defp number_at(values, idx) when is_integer(idx) and idx >= 0 do
    values |> Enum.at(idx) |> to_number()
  end

  defp number_at(_values, _idx), do: 0.0

  defp cell_value(%{"Value" => v}), do: v
  defp cell_value(_), do: nil

  defp to_number(v) when is_integer(v), do: v * 1.0
  defp to_number(v) when is_float(v), do: v

  defp to_number(v) when is_binary(v) do
    case Float.parse(String.replace(v, ",", "")) do
      {n, _} -> n
      :error -> 0.0
    end
  end

  defp to_number(_), do: 0.0

  defp list_assets_by_status(client, status, page \\ 1, acc \\ []) do
    params = [status: status, page: page, pageSize: @asset_page_size]

    with {:ok, body} <- request(client, :get, "#{@assets}/Assets", params: params) do
      items = extract_list(body, "items")
      pagination = if is_map(body), do: body["pagination"] || %{}, else: %{}
      page_count = pagination["pageCount"] || pagination["page_count"] || 1
      acc = acc ++ items

      if items == [] or page >= page_count do
        {:ok, acc}
      else
        list_assets_by_status(client, status, page + 1, acc)
      end
    end
  end

  defp hydrate_assets(client, items, types_by_id) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      id = item["assetId"] || item["AssetId"] || item["AssetID"]

      detail =
        if is_binary(id) and id != "" do
          case request(client, :get, "#{@assets}/Assets/#{id}") do
            {:ok, body} when is_map(body) -> body
            _ -> item
          end
        else
          item
        end

      {:cont, {:ok, acc ++ [normalize_asset(detail, item, types_by_id)]}}
    end)
  end

  defp normalize_asset(detail, list_item, types_by_id) do
    asset = Map.merge(list_item || %{}, detail || %{})
    type_id = asset["assetTypeId"] || asset["AssetTypeId"]
    type = asset["assetType"] || asset["AssetType"] || types_by_id[to_string(type_id)] || %{}
    setting = asset["bookDepreciationSetting"] || asset["BookDepreciationSetting"] || %{}
    book = asset["bookDepreciationDetail"] || asset["BookDepreciationDetail"] || %{}
    history = depreciation_history(asset, book)

    %{
      "AssetId" => asset["assetId"] || asset["AssetId"] || asset["AssetID"],
      "AssetName" => asset["assetName"] || asset["AssetName"],
      "AssetNumber" => asset["assetNumber"] || asset["AssetNumber"],
      "PurchaseDate" => asset["purchaseDate"] || asset["PurchaseDate"],
      "PurchasePrice" => asset["purchasePrice"] || asset["PurchasePrice"],
      "ResidualValue" =>
        book["residualValue"] || book["ResidualValue"] || asset["residualValue"] ||
          asset["ResidualValue"] || 0,
      "DepreciationStartDate" =>
        book["depreciationStartDate"] || book["DepreciationStartDate"] ||
          asset["depreciationStartDate"] || asset["DepreciationStartDate"],
      "BookValue" =>
        asset["accountingBookValue"] || asset["AccountingBookValue"] || asset["bookValue"] ||
          asset["BookValue"],
      "AccountingBookValue" => asset["accountingBookValue"] || asset["AccountingBookValue"],
      "DepreciationMethod" =>
        setting["depreciationMethod"] || setting["DepreciationMethod"] ||
          asset["DepreciationMethod"],
      "AveragingMethod" =>
        setting["averagingMethod"] || setting["AveragingMethod"] || asset["AveragingMethod"],
      "DepreciationRate" =>
        setting["depreciationRate"] || setting["DepreciationRate"] || asset["DepreciationRate"],
      "AssetTypeId" => type_id,
      "AssetType" => normalize_asset_type(type),
      "DepreciationHistory" => history
    }
  end

  defp normalize_asset_type(type) when is_map(type) do
    %{
      "AssetTypeName" => type["assetTypeName"] || type["AssetTypeName"],
      "FixedAssetAccountId" => type["fixedAssetAccountId"] || type["FixedAssetAccountId"],
      "AccumulatedDepreciationAccountId" =>
        type["accumulatedDepreciationAccountId"] || type["AccumulatedDepreciationAccountId"],
      "DepreciationExpenseAccountId" =>
        type["depreciationExpenseAccountId"] || type["DepreciationExpenseAccountId"],
      "DisposalAccountId" => type["disposalAccountId"] || type["DisposalAccountId"]
    }
  end

  defp normalize_asset_type(_), do: %{}

  defp depreciation_history(asset, book) do
    existing = asset["DepreciationHistory"] || asset["depreciationHistory"]

    if is_list(existing) and existing != [] do
      Enum.map(existing, &normalize_history_row/1)
    else
      synthesize_history(asset, book)
    end
  end

  defp normalize_history_row(row) when is_map(row) do
    %{
      "DepreciationDate" => row["DepreciationDate"] || row["depreciationDate"],
      "DepreciationAmount" => row["DepreciationAmount"] || row["depreciationAmount"],
      "CostLimit" => row["CostLimit"] || row["costLimit"]
    }
  end

  defp normalize_history_row(_), do: %{}

  defp synthesize_history(asset, book) do
    pur = to_number(asset["purchasePrice"] || asset["PurchasePrice"] || 0)

    book_value =
      to_number(
        asset["accountingBookValue"] || asset["AccountingBookValue"] || asset["bookValue"] ||
          asset["BookValue"] || pur
      )

    prior =
      to_number(book["priorAccumDepreciationAmount"] || book["PriorAccumDepreciationAmount"])

    current =
      to_number(book["currentAccumDepreciationAmount"] || book["CurrentAccumDepreciationAmount"])

    amount =
      cond do
        prior + current > 0 -> prior + current
        pur - book_value > 0 -> pur - book_value
        true -> 0.0
      end

    if amount == 0.0 do
      []
    else
      [
        %{
          "DepreciationDate" =>
            book["depreciationStartDate"] || book["DepreciationStartDate"] ||
              asset["purchaseDate"] || asset["PurchaseDate"],
          "DepreciationAmount" => amount,
          "CostLimit" => book["costLimit"] || book["CostLimit"] || pur
        }
      ]
    end
  end
end
