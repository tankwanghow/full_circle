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

    @impl true
    def get_trial_balance(client, date) do
      case client do
        %{fail: :get_trial_balance} ->
          {:error, :forced}

        %{payloads: %{get_trial_balance: fun}} when is_function(fun, 1) ->
          {:ok, fun.(date)}

        _ ->
          {:ok, []}
      end
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
    assert {:error, _} =
             Credentials.load("/tmp/xero-missing-#{System.unique_integer([:positive])}")
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
      assert "accounting.settings.read" in scopes
      assert "accounting.contacts.read" in scopes
      assert "accounting.invoices.read" in scopes
      assert "accounting.payments.read" in scopes
      assert "accounting.banktransactions.read" in scopes
      assert "accounting.manualjournals.read" in scopes
      assert "accounting.reports.trialbalance.read" in scopes
      assert "assets.read" in scopes
      # Broad scopes were retired for apps created on/after 2026-03-02.
      refute "accounting.transactions.read" in scopes
      refute "accounting.reports.read" in scopes
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
      assert body["redirect_uri"] == "http://localhost:4099/callback"

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
    assert params["redirect_uri"] == "http://localhost:4099/callback"
    assert params["response_type"] == "code"
    scopes = String.split(params["scope"] || "", " ", trim: true)
    assert "offline_access" in scopes
    assert "accounting.invoices.read" in scopes
    assert "accounting.reports.trialbalance.read" in scopes
    refute "accounting.transactions.read" in scopes
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

  test "append_tokens/2 leaves the credentials file readable only by the owner", %{dir: dir} do
    path = Path.join(dir, ".credentials")
    File.write!(path, "XERO_CLIENT_ID=id1\nXERO_CLIENT_SECRET=sec1\n")

    assert :ok = Credentials.append_tokens(path, %{access_token: "at-x", refresh_token: "rt-x"})

    %File.Stat{mode: mode} = File.stat!(path)
    assert Bitwise.band(mode, 0o777) == 0o600
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

  test "list_contacts includes archived contacts", %{stub: stub} do
    Req.Test.expect(stub, fn conn ->
      assert conn.request_path == "/api.xro/2.0/Contacts"
      assert conn.query_params["includeArchived"] == "true"
      Req.Test.json(conn, %{"Contacts" => []})
    end)

    assert {:ok, []} = HttpClient.list_contacts(http_client(stub))
    Req.Test.verify!(stub)
  end

  test "401 refresh persists the rotated refresh token and uses the new access token", %{
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
    {:ok, hits} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(stub, fn conn ->
      cond do
        conn.host == "identity.xero.com" ->
          body = form_body(conn)
          assert body["grant_type"] == "refresh_token"
          assert body["refresh_token"] == "rt-old"
          Req.Test.json(conn, %{"access_token" => "tok-2", "refresh_token" => "rt-new"})

        true ->
          n = Agent.get_and_update(hits, fn i -> {i, i + 1} end)

          if n == 0 do
            Plug.Conn.send_resp(conn, 401, "expired")
          else
            assert "Bearer tok-2" in Plug.Conn.get_req_header(conn, "authorization")
            Req.Test.json(conn, %{"Invoices" => []})
          end
      end
    end)

    client =
      HttpClient.new(
        access_token: "tok-1",
        tenant_id: "tenant-1",
        credentials: creds,
        req_options: [plug: {Req.Test, stub}]
      )

    assert {:ok, []} = HttpClient.list_invoices(client)

    {:ok, creds2} = Credentials.load(path)
    assert creds2.refresh_token == "rt-new"
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

  test "429 with a Retry-After beyond the cap fails fast instead of sleeping", %{stub: stub} do
    Req.Test.stub(stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "70000")
      |> Plug.Conn.send_resp(429, "daily limit exceeded")
    end)

    {:ok, delays} = Agent.start_link(fn -> [] end)
    sleeper = fn ms -> Agent.update(delays, &(&1 ++ [ms])) end

    assert {:error, {:rate_limited, 70_000}} =
             HttpClient.list_invoices(http_client(stub, sleeper: sleeper))

    assert Agent.get(delays, & &1) == []
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

  test "get_reports fetches TrialBalance and does not call aged reports", %{stub: stub} do
    Req.Test.stub(stub, fn conn ->
      cond do
        String.ends_with?(conn.request_path, "/Reports/TrialBalance") ->
          Req.Test.json(conn, %{
            "Reports" => [
              %{
                "Rows" => [
                  %{
                    "RowType" => "Row",
                    "Cells" => [
                      %{"Value" => "Sales"},
                      %{"Value" => "10.00"},
                      %{"Value" => "0.00"}
                    ]
                  }
                ]
              }
            ]
          })

        String.contains?(conn.request_path, "Aged") ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(400, ~s({"ErrorNumber":400,"Message":"contactID required"}))

        true ->
          Plug.Conn.send_resp(conn, 404, conn.request_path)
      end
    end)

    assert {:ok, reports} = HttpClient.get_reports(http_client(stub))
    assert [%{"account_name" => "Sales", "balance" => 10.0}] = reports["trial_balance"]
    assert reports["aged_receivables"] == []
    assert reports["aged_payables"] == []
  end

  test "trial balance uses YTD columns and keeps blank cells positional", %{stub: stub} do
    Req.Test.stub(stub, fn conn ->
      assert String.ends_with?(conn.request_path, "/Reports/TrialBalance")

      Req.Test.json(conn, %{
        "Reports" => [
          %{
            "Rows" => [
              %{
                "RowType" => "Header",
                "Cells" => [
                  %{"Value" => "Account"},
                  %{"Value" => "Debit"},
                  %{"Value" => "Credit"},
                  %{"Value" => "YTD Debit"},
                  %{"Value" => "YTD Credit"}
                ]
              },
              %{
                "RowType" => "Section",
                "Rows" => [
                  %{
                    "RowType" => "Row",
                    "Cells" => [
                      %{"Value" => "Bank"},
                      %{"Value" => "100.00"},
                      %{"Value" => ""},
                      %{"Value" => "150.00"},
                      %{"Value" => ""}
                    ]
                  },
                  %{
                    "RowType" => "Row",
                    "Cells" => [
                      %{"Value" => "Sales"},
                      %{"Value" => ""},
                      %{"Value" => "40.00"},
                      %{"Value" => ""},
                      %{"Value" => "240.00"}
                    ]
                  }
                ]
              }
            ]
          }
        ]
      })
    end)

    assert {:ok, reports} = HttpClient.get_reports(http_client(stub))

    assert [
             %{"account_name" => "Bank", "balance" => 150.0},
             %{"account_name" => "Sales", "balance" => -240.0}
           ] = reports["trial_balance"]
  end

  test "GET /Setup 404 yields empty conversion balances", %{stub: stub} do
    Req.Test.expect(stub, fn conn ->
      assert conn.request_path == "/api.xro/2.0/Setup"
      Plug.Conn.send_resp(conn, 404, "")
    end)

    assert {:ok, %{"Date" => nil, "Lines" => []}} =
             HttpClient.get_conversion_balances(http_client(stub))

    Req.Test.verify!(stub)
  end

  test "conversion date uses Day when present", %{stub: stub} do
    Req.Test.expect(stub, fn conn ->
      assert conn.request_path == "/api.xro/2.0/Setup"

      Req.Test.json(conn, %{
        "ConversionDate" => %{"Year" => 2024, "Month" => 1, "Day" => 15},
        "ConversionBalances" => [%{"AccountCode" => "090", "Balance" => 1.0}]
      })
    end)

    assert {:ok, cb} = HttpClient.get_conversion_balances(http_client(stub))
    assert cb["Date"] == "2024-01-15"
    Req.Test.verify!(stub)
  end

  test "list_fixed_assets requests status, pageSize, AssetTypes and asset details", %{stub: stub} do
    Req.Test.stub(stub, fn conn ->
      cond do
        conn.request_path == "/assets.xro/1.0/AssetTypes" ->
          Req.Test.json(conn, [
            %{
              "assetTypeId" => "fat-1",
              "assetTypeName" => "Vehicles",
              "fixedAssetAccountId" => "ac-fa",
              "accumulatedDepreciationAccountId" => "ac-accum",
              "depreciationExpenseAccountId" => "ac-depre"
            }
          ])

        conn.request_path == "/assets.xro/1.0/Assets" ->
          assert conn.query_params["pageSize"] == "200"
          assert conn.query_params["status"] in ["REGISTERED", "DISPOSED"]

          items =
            if conn.query_params["status"] == "REGISTERED" do
              [%{"assetId" => "fa-1", "assetName" => "Van", "assetTypeId" => "fat-1"}]
            else
              []
            end

          Req.Test.json(conn, %{
            "pagination" => %{"page" => 1, "pageCount" => 1, "pageSize" => 200},
            "items" => items
          })

        conn.request_path == "/assets.xro/1.0/Assets/fa-1" ->
          Req.Test.json(conn, %{
            "assetId" => "fa-1",
            "assetName" => "Van",
            "purchaseDate" => "2023-01-01",
            "purchasePrice" => 1000.0,
            "assetTypeId" => "fat-1",
            "accountingBookValue" => 800.0,
            "bookDepreciationSetting" => %{
              "depreciationMethod" => "StraightLine",
              "depreciationRate" => nil,
              "effectiveLifeYears" => 5,
              "averagingMethod" => "Monthly"
            },
            "bookDepreciationDetail" => %{
              "residualValue" => 0,
              "depreciationStartDate" => "2023-01-01",
              "priorAccumDepreciationAmount" => 200.0,
              "currentAccumDepreciationAmount" => 0.0
            }
          })

        true ->
          Plug.Conn.send_resp(conn, 404, conn.request_path)
      end
    end)

    assert {:ok, [asset]} = HttpClient.list_fixed_assets(http_client(stub))
    assert asset["AssetId"] == "fa-1"
    assert asset["AssetName"] == "Van"
    assert asset["DepreciationMethod"] == "StraightLine"
    assert asset["EffectiveLifeYears"] == 5
    assert asset["AssetType"]["FixedAssetAccountId"] == "ac-fa"
    assert [%{"DepreciationAmount" => 200.0}] = asset["DepreciationHistory"]
  end

  test "pull collects a trial balance per financial year end", %{dir: dir} do
    dest = Path.join(dir, "snap-yearly")
    today = Date.utc_today()

    client = %FakeClient{
      payloads: %{
        get_organisation: %{
          "Name" => "Pulled Org",
          "FinancialYearEndMonth" => 12,
          "FinancialYearEndDay" => 31
        },
        list_invoices: [
          %{
            "InvoiceID" => "a",
            "Type" => "ACCREC",
            "Status" => "PAID",
            "Total" => 5.0,
            "DateString" => "#{today.year - 2}-06-01T00:00:00"
          }
        ],
        get_trial_balance: fn date ->
          [%{"account_name" => "Sales", "balance" => date.year * 1.0}]
        end
      }
    }

    assert {:ok, ^dest} = Snapshot.pull(client, dest)
    assert {:ok, snap} = Snapshot.read(dest)

    periods = snap.reports["trial_balance_by_year"]
    dates = Enum.map(periods, & &1["date"])

    assert "#{today.year - 2}-12-31" in dates
    assert "#{today.year - 1}-12-31" in dates
    assert List.last(dates) == Date.to_iso8601(today)

    fye = Enum.find(periods, &(&1["date"] == "#{today.year - 1}-12-31"))
    assert [%{"account_name" => "Sales", "balance" => bal}] = fye["lines"]
    assert bal == (today.year - 1) * 1.0
  end

  test "pull excludes zero-total docs from invoice totals", %{dir: dir} do
    dest = Path.join(dir, "snap-zero")

    client = %FakeClient{
      payloads: %{
        list_invoices: [
          %{"InvoiceID" => "a", "Type" => "ACCREC", "Status" => "PAID", "Total" => 50.0},
          %{"InvoiceID" => "z", "Type" => "ACCREC", "Status" => "PAID", "Total" => 0.0}
        ]
      }
    }

    assert {:ok, ^dest} = Snapshot.pull(client, dest)
    assert {:ok, snap} = Snapshot.read(dest)
    assert snap.reports["invoice_totals"] == %{"count" => 1, "amount" => 50.0}
  end

  test "pull fills aged from contact outstanding when aged reports are empty", %{dir: dir} do
    dest = Path.join(dir, "snap-aged")

    client = %FakeClient{
      payloads: %{
        list_contacts: [
          %{
            "ContactID" => "c1",
            "Name" => "Alice Customer",
            "Balances" => %{"AccountsReceivable" => %{"Outstanding" => 120.0}}
          },
          %{
            "ContactID" => "c2",
            "Name" => "Bob Supplier",
            "Balances" => %{"AccountsPayable" => %{"Outstanding" => 30.0}}
          }
        ]
      }
    }

    assert {:ok, ^dest} = Snapshot.pull(client, dest)
    assert {:ok, snap} = Snapshot.read(dest)

    assert [%{"contact_name" => "Alice Customer", "balance" => 120.0}] =
             snap.reports["aged_receivables"]

    assert [%{"contact_name" => "Bob Supplier", "balance" => -30.0}] =
             snap.reports["aged_payables"]
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
