defmodule FullCircle.XeroImport.Credentials do
  @moduledoc false

  @default_path "priv/xero_import/.credentials"
  @token_url "https://identity.xero.com/connect/token"
  @authorize_url "https://login.xero.com/identity/connect/authorize"
  @redirect_uri "http://127.0.0.1:4099/callback"
  @auth_ip {127, 0, 0, 1}
  @auth_port 4099

  @scopes [
    "accounting.transactions.read",
    "accounting.contacts.read",
    "accounting.settings.read",
    "accounting.reports.read",
    "assets.read"
  ]

  def default_path, do: @default_path
  def redirect_uri, do: @redirect_uri
  def scopes, do: @scopes
  def web_scopes, do: @scopes ++ ["offline_access"]

  def load(path) do
    with {:ok, bin} <- File.read(path) do
      raw = parse_dotenv(bin)
      client_id = blank_to_nil(raw["XERO_CLIENT_ID"])
      client_secret = blank_to_nil(raw["XERO_CLIENT_SECRET"])

      if client_id && client_secret do
        {:ok,
         %{
           client_id: client_id,
           client_secret: client_secret,
           tenant_id: blank_to_nil(raw["XERO_TENANT_ID"]),
           refresh_token: blank_to_nil(raw["XERO_REFRESH_TOKEN"]),
           access_token: blank_to_nil(raw["XERO_ACCESS_TOKEN"]),
           path: path
         }}
      else
        {:error, :missing_client_credentials}
      end
    else
      {:error, reason} -> {:error, {:credentials_file, reason}}
    end
  end

  def token(creds, opts \\ []) do
    req_options = Keyword.get(opts, :req_options, [])

    if present?(field(creds, :refresh_token)) do
      post_token(
        creds,
        [grant_type: "refresh_token", refresh_token: field(creds, :refresh_token)],
        req_options
      )
    else
      post_token(
        creds,
        [grant_type: "client_credentials", scope: Enum.join(scopes(), " ")],
        req_options
      )
    end
  end

  def exchange_code(creds, code, opts \\ []) do
    post_token(
      creds,
      [grant_type: "authorization_code", code: code, redirect_uri: @redirect_uri],
      Keyword.get(opts, :req_options, [])
    )
  end

  def authorize_url(creds, opts \\ []) do
    state = Keyword.get(opts, :state) || random_state()

    params = %{
      "response_type" => "code",
      "client_id" => field(creds, :client_id),
      "redirect_uri" => @redirect_uri,
      "scope" => Enum.join(web_scopes(), " "),
      "state" => state
    }

    @authorize_url <> "?" <> URI.encode_query(params)
  end

  def append_tokens(path, tokens) do
    existing =
      case File.read(path) do
        {:ok, bin} -> bin
        _ -> ""
      end

    updates =
      %{}
      |> maybe_put("XERO_ACCESS_TOKEN", token_field(tokens, :access_token))
      |> maybe_put("XERO_REFRESH_TOKEN", token_field(tokens, :refresh_token))

    File.write(path, upsert_pairs(existing, updates))
  end

  def await_code(opts \\ []) do
    port = Keyword.get(opts, :port, @auth_port)
    timeout = Keyword.get(opts, :timeout, 300_000)

    {:ok, listen} =
      :gen_tcp.listen(port, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: @auth_ip
      ])

    try do
      case :gen_tcp.accept(listen, timeout) do
        {:ok, sock} -> handle_callback(sock)
        {:error, reason} -> {:error, reason}
      end
    after
      :gen_tcp.close(listen)
    end
  end

  defp handle_callback(sock) do
    result =
      case recv_http(sock, "") do
        {:ok, data} ->
          html = ~s(<html><body>Xero authorised. You can close this tab.</body></html>)

          _ =
            :gen_tcp.send(sock, [
              "HTTP/1.1 200 OK\r\n",
              "Content-Type: text/html; charset=utf-8\r\n",
              "Connection: close\r\n",
              "Content-Length: #{byte_size(html)}\r\n\r\n",
              html
            ])

          parse_callback(data)

        {:error, reason} ->
          {:error, reason}
      end

    :gen_tcp.close(sock)
    result
  end

  defp recv_http(sock, acc) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, data} ->
        acc = acc <> data

        if String.contains?(acc, "\r\n\r\n") do
          {:ok, acc}
        else
          recv_http(sock, acc)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_callback(data) do
    first = data |> String.split("\r\n", parts: 2) |> hd()

    path =
      case String.split(first, " ") do
        [_method, path | _] -> path
        _ -> nil
      end

    params =
      case path && URI.parse(path) do
        %URI{query: query} when is_binary(query) -> URI.decode_query(query)
        _ -> %{}
      end

    cond do
      present?(params["code"]) ->
        {:ok, params["code"]}

      present?(params["error"]) ->
        {:error, {:oauth_error, params["error"], params["error_description"]}}

      true ->
        {:error, :missing_code}
    end
  end

  defp post_token(creds, form, req_options) do
    opts =
      [
        auth: {:basic, "#{field(creds, :client_id)}:#{field(creds, :client_secret)}"},
        form: form,
        retry: false
      ]
      |> Keyword.merge(req_options)

    case Req.post(@token_url, opts) do
      {:ok, %{status: 200, body: body}} ->
        parse_token_body(body)

      {:ok, %{status: status, body: body}} ->
        {:error, {:token_http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_token_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} -> parse_token_body(map)
      {:error, _} = err -> err
    end
  end

  defp parse_token_body(body) when is_map(body) do
    case body["access_token"] do
      token when is_binary(token) and token != "" ->
        {:ok, %{access_token: token, refresh_token: body["refresh_token"]}}

      _ ->
        {:error, {:invalid_token_response, body}}
    end
  end

  defp parse_dotenv(bin) do
    bin
    |> String.split(~r/\r?\n/)
    |> Enum.reduce(%{}, fn line, acc ->
      line = String.trim(line)

      cond do
        line == "" or String.starts_with?(line, "#") ->
          acc

        String.contains?(line, "=") ->
          [key | rest] = String.split(line, "=", parts: 2)
          Map.put(acc, String.trim(key), unwrap_value(Enum.join(rest, "=")))

        true ->
          acc
      end
    end)
  end

  defp unwrap_value(val) do
    val = String.trim(val)

    cond do
      String.length(val) >= 2 and String.starts_with?(val, "\"") and String.ends_with?(val, "\"") ->
        String.slice(val, 1, String.length(val) - 2)

      String.length(val) >= 2 and String.starts_with?(val, "'") and String.ends_with?(val, "'") ->
        String.slice(val, 1, String.length(val) - 2)

      true ->
        val
    end
  end

  defp upsert_pairs(text, updates) do
    lines = String.split(text, ~r/\r?\n/, trim: true)

    {seen, out} =
      Enum.reduce(lines, {MapSet.new(), []}, fn line, {seen, acc} ->
        case String.split(String.trim(line), "=", parts: 2) do
          [k, _] ->
            k = String.trim(k)

            if Map.has_key?(updates, k) do
              {MapSet.put(seen, k), acc ++ ["#{k}=#{updates[k]}"]}
            else
              {seen, acc ++ [line]}
            end

          _ ->
            {seen, acc ++ [line]}
        end
      end)

    extras =
      updates
      |> Enum.reject(fn {k, _} -> MapSet.member?(seen, k) end)
      |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)

    Enum.join(out ++ extras, "\n") <> "\n"
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp token_field(tokens, key) when is_map(tokens) do
    Map.get(tokens, key) || Map.get(tokens, Atom.to_string(key))
  end

  defp field(creds, key) when is_map(creds) do
    Map.get(creds, key) || Map.get(creds, Atom.to_string(key))
  end

  defp present?(val), do: is_binary(val) and val != ""

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(val) when is_binary(val) do
    case String.trim(val) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp random_state do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
