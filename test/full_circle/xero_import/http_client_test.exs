defmodule FullCircle.XeroImport.HttpClientTest do
  use ExUnit.Case, async: true

  alias FullCircle.XeroImport.{Client, Credentials, HttpClient, Snapshot}

  defmodule FakeClient do
    @behaviour FullCircle.XeroImport.Client

    defstruct fail: nil, payloads: %{}

    @impl true
    def get_organisation(client), do: reply(client, :get_organisation, %{"Name" => "Pulled Org"})

    @impl true
    def list_accounts(client), do: reply(client, :list_accounts, [])

    @impl true
    def list_tax_rates(client), do: reply(client, :list_tax_rates, [])

    @impl true
    def list_contacts(client), do: reply(client, :list_contacts, [])

    @impl true
    def list_items(client), do: reply(client, :list_items, [])

    @impl true
    def list_invoices(client), do: reply(client, :list_invoices, [])

    @impl true
    def list_credit_notes(client), do: reply(client, :list_credit_notes, [])

    @impl true
    def list_payments(client), do: reply(client, :list_payments, [])

    @impl true
    def list_bank_transactions(client), do: reply(client, :list_bank_transactions, [])

    @impl true
    def list_bank_transfers(client), do: reply(client, :list_bank_transfers, [])

    @impl true
    def list_manual_journals(client), do: reply(client, :list_manual_journals, [])

    @impl true
    def list_fixed_assets(client), do: reply(client, :list_fixed_assets, [])

    @impl true
    def get_conversion_balances(client) do
      reply(client, :get_conversion_balances, %{"Date" => "2024-01-01", "Lines" => []})
    end

    @impl true
    def get_reports(client) do
      reply(client, :get_reports, %{
        "trial_balance" => [],
        "aged_receivables" => [],
        "aged_payables" => []
      })
    end

    defp reply(%{fail: fail}, name, _default) when fail == name, do: {:error, :forced}
    defp reply(%{payloads: payloads}, name, default), do: {:ok, Map.get(payloads, name, default)}
    defp reply(_client, _name, default), do: {:ok, default}
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "xero-http-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir, stub: __MODULE__}
  end

  test "Client is a behaviour with one callback per snapshot file" do
    callbacks = Keyword.keys(Client.behaviour_info(:callbacks))

    for name <- [
          :get_organisation,
          :list_accounts,
          :list_tax_rates,
          :list_contacts,
          :list_items,
          :list_invoices,
          :list_credit_notes,
          :list_payments,
          :list_bank_transactions,
          :list_bank_transfers,
          :list_manual_journals,
          :list_fixed_assets,
          :get_conversion_balances,
          :get_reports
        ] do
      assert name in callbacks
    end
  end

  test "load/1 parses dotenv credentials and blanks", %{dir: dir} do
    path = Path.join(dir, ".credentials")

    File.write!(path, """
    # comment
    XERO_CLIENT_ID=id1
    XERO_CLIENT_SECRET="sec ret"
    XERO_TENANT_ID=
    XERO_REFRESH_TOKEN=
    """)

    assert {:ok, creds} = Credentials.load(path)
    assert creds.client_id == "id1"
    assert creds.client_secret == "sec ret"
    assert creds.tenant_id in [nil, ""]
    assert creds.refresh_token in [nil, ""]
  end

  test "load/1 errors when the file is missing" do
    assert {:error, _} = Credentials.load("/tmp/xero-missing-#{System.unique_integer([:positive])}")
  end

  test "load/1 errors when client id or secret is missing", %{dir: dir} do
    path = Path.join(dir, "partial")
    File.write!(path, "XERO_CLIENT_ID=only-id\n")
    assert {:error, _} = Credentials.load(path)
  end

  test "token/1 posts client_credentials with spec scopes and no journals.read", %{
    dir: dir,
    stub: stub
  } do
    path = Path.join(dir, ".credentials")
    File.write!(path, "XERO_CLIENT_ID=id1\nXERO_CLIENT_SECRET=sec1\n")
    {:ok, creds} = Credentials.load(path)

    Req.Test.expect(stub, fn conn ->
      assert conn.method == "POST"
      assert conn.host == "identity.xero.com"
      assert conn.request_path == "/connect/token"
      body = form_body(conn)
      assert body["grant_type"] == "client_credentials"
      scopes = String.split(body["scope"] || "", " ", trim: true)
      assert "accounting.transactions.read" in scopes
      assert "accounting.contacts.read" in scopes
      assert "accounting.settings.read" in scopes
      assert "accounting.reports.read" in scopes
      assert "assets.read" in scopes
      refute "accounting.journals.read" in scopes
      refute "offline_access" in scopes
      assert Plug.Conn.get_req_header(conn, "authorization") != []

      Req.Test.json(conn, %{
        "access_token" => "tok-cc",
        "token_type" => "Bearer",
        "expires_in" => 1800
      })
    end)

    assert {:ok, tokens} = Credentials.token(creds, req_options: [plug: {Req.Test, stub}])
    assert tokens.access_token == "tok-cc"
    Req.Test.verify!(stub)
  end

  test "token/1 uses refresh_token grant when XERO_REFRESH_TOKEN is present", %{
    dir: dir,
    stub: stub
  } do
    path = Path.join(dir, ".credentials")

    File.write!(path, """
    XERO_CLIENT_ID=id1
    XERO_CLIENT_SECRET=sec1
    XERO_REFRESH_TOKEN=rt-old
    """)

    {:ok, creds} = Credentials.load(path)

    Req.Test.expect(stub, fn conn ->
      body = form_body(conn)
      assert body["grant_type"] == "refresh_token"
      assert body["refresh_token"] == "rt-old"
      refute String.contains?(body["scope"] || "", "accounting.journals.read")

      Req.Test.json(conn, %{
        "access_token" => "tok-rt",
        "refresh_token" => "rt-new",
        "token_type" => "Bearer"
      })
    end)

    assert {:ok, tokens} = Credentials.token(creds, req_options: [plug: {Req.Test, stub}])
    assert tokens.access_token == "tok-rt"
    assert tokens.refresh_token == "rt-new"
    Req.Test.verify!(stub)
  end

  test "exchange_code/3 posts authorization_code and parses tokens", %{dir: dir, stub: stub} do
    path = Path.join(dir, ".credentials")
    File.write!(path, "XERO_CLIENT_ID=id1\nXERO_CLIENT_SECRET=sec1\n")
    {:ok, creds} = Credentials.load(path)

    Req.Test.expect(stub, fn conn ->
      assert conn.method == "POST"
      assert conn.host == "identity.xero.com"
      body = form_body(conn)
      assert body["grant_type"] == "authorization_code"
      assert body["code"] == "abc-code"
      assert body["redirect_uri"] == "http://127.0.0.1:4099/callback"

      Req.Test.json(conn, %{
        "access_token" => "at-1",
        "refresh_token" => "rt-1",
        "expires_in" => 1800
      })
    end)

    assert {:ok, %{access_token: "at-1", refresh_token: "rt-1"}} =
             Credentials.exchange_code(creds, "abc-code", req_options: [plug: {Req.Test, stub}])

    Req.Test.verify!(stub)
  end

  test "authorize_url/1 is the Xero authorize endpoint with web scopes and no journals.read" do
    url = Credentials.authorize_url(%{client_id: "id1"})
    uri = URI.parse(url)
    assert uri.scheme == "https"
    assert uri.host == "login.xero.com"
    assert uri.path == "/identity/connect/authorize"
    params = URI.decode_query(uri.query)
    assert params["client_id"] == "id1"
    assert params["redirect_uri"] == "http://127.0.0.1:4099/callback"
    assert params["response_type"] == "code"
    scopes = String.split(params["scope"] || "", " ", trim: true)
    assert "offline_access" in scopes
    assert "accounting.transactions.read" in scopes
    refute "accounting.journals.read" in scopes
  end

  test "append_tokens/2 writes access and refresh tokens without dropping client id", %{dir: dir} do
    path = Path.join(dir, ".credentials")
    File.write!(path, "XERO_CLIENT_ID=id1\nXERO_CLIENT_SECRET=sec1\n")

    assert :ok =
             Credentials.append_tokens(path, %{access_token: "at-x", refresh_token: "rt-x"})

    {:ok, creds} = Credentials.load(path)
    assert creds.client_id == "id1"
    assert creds.access_token == "at-x"
    assert creds.refresh_token == "rt-x"
  end

  test "list_invoices/1 assembles pages until empty", %{stub: stub} do
    Req.Test.expect(stub, fn conn ->
      assert conn.method == "GET"
      assert conn.host == "api.xero.com"
      assert conn.request_path == "/api.xro/2.0/Invoices"
      assert conn.query_params["page"] == "1"
      assert_xero_headers(conn)
      Req.Test.json(conn, %{"Invoices" => [%{"InvoiceID" => "a"}]})
    end)

    Req.Test.expect(stub, fn conn ->
      assert conn.query_params["page"] == "2"
      Req.Test.json(conn, %{"Invoices" => [%{"InvoiceID" => "b"}]})
    end)

    Req.Test.expect(stub, fn conn ->
      assert conn.query_params["page"] == "3"
      Req.Test.json(conn, %{"Invoices" => []})
    end)

    client = http_client(stub)
    assert {:ok, invoices} = HttpClient.list_invoices(client)
    assert Enum.map(invoices, & &1["InvoiceID"]) == ["a", "b"]
    Req.Test.verify!(stub)
  end

  test "retries 429 using Retry-After then succeeds", %{stub: stub} do
    {:ok, hits} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(stub, fn conn ->
      n = Agent.get_and_update(hits, fn i -> {i, i + 1} end)

      if n == 0 do
        conn
        |> Plug.Conn.put_resp_header("retry-after", "0")
        |> Plug.Conn.send_resp(429, "slow down")
      else
        Req.Test.json(conn, %{"Invoices" => []})
      end
    end)

    assert {:ok, []} = HttpClient.list_invoices(http_client(stub))
    assert Agent.get(hits, & &1) >= 2
  end

  test "429 without Retry-After backs off 2/4/8s (injected sleeper)", %{stub: stub} do
    {:ok, hits} = Agent.start_link(fn -> 0 end)
    {:ok, delays} = Agent.start_link(fn -> [] end)

    Req.Test.stub(stub, fn conn ->
      n = Agent.get_and_update(hits, fn i -> {i, i + 1} end)

      if n < 3 do
        Plug.Conn.send_resp(conn, 429, "slow")
      else
        Req.Test.json(conn, %{"Invoices" => []})
      end
    end)

    sleeper = fn ms -> Agent.update(delays, &(&1 ++ [ms])) end
    client = http_client(stub, sleeper: sleeper)
    assert {:ok, []} = HttpClient.list_invoices(client)
    assert Agent.get(delays, & &1) == [2_000, 4_000, 8_000]
  end

  test "429 still failing after max retries is an error", %{stub: stub} do
    Req.Test.stub(stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "0")
      |> Plug.Conn.send_resp(429, "nope")
    end)

    assert {:error, :too_many_requests} = HttpClient.list_invoices(http_client(stub))
  end

  test "pull/2 writes snapshot JSON and replaces dest", %{dir: dir} do
    dest = Path.join(dir, "snap")
    File.mkdir_p!(dest)
    File.write!(Path.join(dest, "stale.txt"), "old")

    assert {:ok, ^dest} = Snapshot.pull(%FakeClient{}, dest)
    refute File.exists?(Path.join(dest, "stale.txt"))
    refute File.exists?(dest <> ".tmp")
    assert {:ok, snap} = Snapshot.read(dest)
    assert snap.organisation["Name"] == "Pulled Org"
    assert is_list(snap.invoices)
    assert is_map(snap.reports)
  end

  test "failed pull leaves dest and does not keep tmp", %{dir: dir} do
    dest = Path.join(dir, "snap")
    File.mkdir_p!(dest)
    File.write!(Path.join(dest, "organisation.json"), ~s({"Name":"Keep Me"}))
    File.write!(Path.join(dest, "marker.txt"), "stay")

    assert {:error, :forced} = Snapshot.pull(%FakeClient{fail: :list_invoices}, dest)
    assert File.read!(Path.join(dest, "organisation.json")) == ~s({"Name":"Keep Me"})
    assert File.read!(Path.join(dest, "marker.txt")) == "stay"
    refute File.exists?(dest <> ".tmp")
  end

  defp http_client(stub, opts \\ []) do
    HttpClient.new(
      Keyword.merge(
        [
          access_token: "tok",
          tenant_id: "tenant-1",
          req_options: [plug: {Req.Test, stub}]
        ],
        opts
      )
    )
  end

  defp assert_xero_headers(conn) do
    assert "Bearer tok" in Plug.Conn.get_req_header(conn, "authorization")
    assert "tenant-1" in Plug.Conn.get_req_header(conn, "xero-tenant-id")
  end

  defp form_body(conn) do
    (Req.Test.raw_body(conn) || "")
    |> to_string()
    |> URI.decode_query()
  end
end
