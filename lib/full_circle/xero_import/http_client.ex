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
    {:ok, pid} = Agent.start_link(fn -> token end)

    %__MODULE__{
      token_agent: pid,
      tenant_id: Keyword.fetch!(opts, :tenant_id),
      credentials: Keyword.get(opts, :credentials),
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
  def list_contacts(client), do: get_pages(client, "#{@accounting}/Contacts", "Contacts")

  @impl true
  def list_items(client), do: get_pages(client, "#{@accounting}/Items", "Items")

  @impl true
  def list_invoices(client), do: get_pages(client, "#{@accounting}/Invoices", "Invoices")

  @impl true
  def list_credit_notes(client), do: get_pages(client, "#{@accounting}/CreditNotes", "CreditNotes")

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

  @impl true
  def list_fixed_assets(client), do: get_pages(client, "#{@assets}/Assets", "items")

  @impl true
  def get_conversion_balances(client) do
    with {:ok, body} <- request(client, :get, "#{@accounting}/Setup") do
      {:ok, normalize_setup(body)}
    end
  end

  @impl true
  def get_reports(client) do
    with {:ok, tb} <- request(client, :get, "#{@accounting}/Reports/TrialBalance"),
         {:ok, ar} <- request(client, :get, "#{@accounting}/Reports/AgedReceivablesByContact"),
         {:ok, ap} <- request(client, :get, "#{@accounting}/Reports/AgedPayablesByContact") do
      {:ok,
       %{
         "trial_balance" => parse_trial_balance(tb),
         "aged_receivables" => parse_aged(ar, :ar),
         "aged_payables" => parse_aged(ap, :ap)
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

  defp get_pages(client, url, key, page \\ 1, acc \\ []) do
    with {:ok, body} <- request(client, :get, url, params: [page: page]) do
      items = extract_list(body, key)

      cond do
        items == [] ->
          {:ok, acc}

        page > 1 and repeated_page?(items, acc) ->
          {:ok, acc}

        page >= 10_000 ->
          {:ok, acc ++ items}

        true ->
          get_pages(client, url, key, page + 1, acc ++ items)
      end
    end
  end

  defp repeated_page?([head | _], acc), do: Enum.any?(acc, &(&1 == head))
  defp repeated_page?(_, _), do: false

  defp request(client, method, url, opts \\ []) do
    request_loop(client, method, url, opts, 1, false)
  end

  defp request_loop(client, method, url, opts, attempt, refreshed) do
    token = Agent.get(client.token_agent, & &1)

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

  defp refresh_token(%{credentials: nil}), do: {:error, :unauthorized}

  defp refresh_token(client) do
    case Credentials.token(client.credentials, req_options: client.req_options) do
      {:ok, %{access_token: token}} ->
        Agent.update(client.token_agent, fn _ -> token end)
        {:ok, client}

      {:error, _} = err ->
        err
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

  defp conversion_date(%{"Year" => year, "Month" => month}) do
    "#{year}-#{String.pad_leading(to_string(month), 2, "0")}-01"
  end

  defp conversion_date(other) when is_binary(other), do: other
  defp conversion_date(_), do: nil

  defp parse_trial_balance(body) do
    body
    |> report_rows()
    |> walk_detail_rows()
    |> Enum.flat_map(&tb_line/1)
  end

  defp parse_aged(body, kind) do
    sign = if kind == :ap, do: -1, else: 1

    Enum.flat_map(report_rows(body), fn
      %{"RowType" => "Section", "Title" => title, "Rows" => inner}
      when is_binary(title) and title != "" ->
        if title in ["Total"] do
          []
        else
          [%{"contact_name" => title, "balance" => sign * section_total(inner)}]
        end

      _ ->
        []
    end)
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

  defp tb_line(%{"Cells" => cells}) do
    values = Enum.map(cells || [], &cell_value/1)
    name = Enum.find(values, &(is_binary(&1) and &1 != "" and not numeric?(&1)))
    nums = values |> Enum.filter(&numeric?/1) |> Enum.map(&to_number/1)

    cond do
      is_nil(name) or name in ["Total", "Opening Balances"] ->
        []

      true ->
        {debit, credit} =
          case nums do
            [d, c | _] -> {d, c}
            [d] -> {d, 0.0}
            [] -> {0.0, 0.0}
          end

        [%{"account_name" => name, "balance" => debit - credit}]
    end
  end

  defp tb_line(_), do: []

  defp section_total(rows) do
    summary = Enum.find(rows || [], &match?(%{"RowType" => "SummaryRow"}, &1))
    cells = (summary || List.last(rows || []) || %{})["Cells"] || []

    cells
    |> Enum.map(&cell_value/1)
    |> Enum.filter(&numeric?/1)
    |> List.last()
    |> to_number()
  end

  defp cell_value(%{"Value" => v}), do: v
  defp cell_value(_), do: nil

  defp numeric?(v) when is_number(v), do: true

  defp numeric?(v) when is_binary(v) do
    case Float.parse(String.replace(v, ",", "")) do
      {_, ""} -> true
      _ -> false
    end
  end

  defp numeric?(_), do: false

  defp to_number(v) when is_integer(v), do: v * 1.0
  defp to_number(v) when is_float(v), do: v

  defp to_number(v) when is_binary(v) do
    case Float.parse(String.replace(v, ",", "")) do
      {n, _} -> n
      :error -> 0.0
    end
  end

  defp to_number(_), do: 0.0
end
