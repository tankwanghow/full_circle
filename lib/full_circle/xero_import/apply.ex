defmodule FullCircle.XeroImport.Apply do
  import Ecto.Query, warn: false

  alias FullCircle.{
    Accounting,
    Billing,
    BillPay,
    DebCre,
    JournalEntry,
    Product,
    ReceiveFund,
    Repo,
    Seeding,
    Sys
  }

  alias FullCircle.Accounting.{Contact, Transaction}
  alias FullCircle.Billing.Invoice
  alias FullCircle.Sys.{Company, CompanyUser}
  alias FullCircle.XeroImport.{Gapless, Mapper}

  @default_company_name "Golden Husbandry Sdn. Bhd."

  @default_control_accounts %{
    "Accounts Receivable" => "Account Receivables",
    "Accounts Payable" => "Account Payables",
    "GST" => "Sales Tax Payable"
  }

  @xero_line_good "__xero_line__"

  def run(snapshot, user, opts \\ []) do
    overrides = Keyword.get(opts, :overrides) || %{}
    name = Keyword.get(opts, :company_name, @default_company_name)
    reset? = Keyword.get(opts, :reset, false) == true

    with {:ok, company} <- ensure_company(snapshot, user, name, reset?),
         ctx <- %{
           snapshot: snapshot,
           user: user,
           company: company,
           overrides: overrides,
           id_map: %{},
           accounts_by_code: %{},
           account_names: %{},
           tax_by_type: %{},
           goods_by_code: %{},
           goods_names: %{},
           invoice_info: %{},
           imported_numbers: %{
             Invoice: [],
             PurInvoice: [],
             Receipt: [],
             Payment: [],
             CreditNote: [],
             DebitNote: [],
             Journal: []
           }
         },
         {:ok, ctx} <- import_accounts(ctx),
         {:ok, ctx} <- import_tax_codes(ctx),
         {:ok, ctx} <- import_contacts(ctx),
         {:ok, ctx} <- import_goods(ctx),
         {:ok, ctx} <- import_fixed_assets(ctx) do
      if Keyword.get(opts, :stop_after) == :masters do
        {:ok, result(ctx)}
      else
        with {:ok, ctx} <- seed_conversion_balances(ctx),
             {:ok, ctx} <- import_invoices_and_bills(ctx),
             {:ok, ctx} <- import_notes(ctx),
             {:ok, ctx} <- import_receipts_and_payments(ctx),
             {:ok, ctx} <- import_journals(ctx),
             {:ok, ctx} <- import_bank(ctx),
             :ok <- Gapless.bump(ctx.company, ctx.imported_numbers) do
          {:ok, result(ctx)}
        end
      end
    end
  end

  defp result(ctx), do: %{company: ctx.company, id_map: ctx.id_map}

  def plan(snapshot, opts \\ %{})

  def plan(snapshot, opts) when is_map(snapshot) do
    overrides = plan_opt(opts, :overrides, %{}) || %{}
    base = organisation(snapshot)["BaseCurrency"] || "MYR"

    %{
      snapshot: snapshot,
      overrides: overrides,
      base: base,
      ops: [],
      errors: [],
      invoice_ids: MapSet.new(),
      invoice_types: %{},
      account_codes: %{},
      tax_by_type: %{}
    }
    |> plan_accounts()
    |> plan_tax_codes()
    |> plan_contacts()
    |> plan_goods()
    |> plan_fixed_assets()
    |> plan_invoices()
    |> plan_notes()
    |> plan_payments()
    |> plan_journals()
    |> plan_bank()
    |> then(fn state -> {Enum.reverse(state.ops), Enum.reverse(state.errors)} end)
  end

  def plan(_snapshot, _opts), do: {[], [:invalid_snapshot]}

  defp plan_opt(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)

  defp plan_opt(opts, key, default) when is_map(opts) do
    Map.get(opts, key) || Map.get(opts, Atom.to_string(key)) || default
  end

  defp plan_opt(_opts, _key, default), do: default

  defp plan_accounts(state) do
    Enum.reduce(rows(state.snapshot.accounts), state, fn xero, state ->
      case Mapper.account_type(xero["Type"], state.overrides) do
        {:ok, account_type} ->
          xero_id = to_string(xero["AccountID"] || xero["AccountId"] || "")
          name = xero["Name"]
          code = xero["Code"]

          state =
            if is_binary(code) and code != "" do
              put_in(state, [:account_codes, code], name)
            else
              state
            end

          add_op(state, {:accounts, %{id: xero_id, name: name, account_type: account_type}})

        {:error, err} ->
          add_error(state, err)
      end
    end)
  end

  defp plan_tax_codes(state) do
    Enum.reduce(rows(state.snapshot.tax_rates), state, fn rate, state ->
      codes = Mapper.tax_codes(rate)
      xero_type = rate["TaxType"]
      entries = Enum.map(codes, &%{tax_type: &1.tax_type, code: &1.code})
      put_in(state, [:tax_by_type, xero_type], entries)
    end)
  end

  defp plan_contacts(state) do
    Enum.reduce(rows(state.snapshot.contacts), state, fn xero, state ->
      add_op(state, {:contacts, Mapper.contact(xero)})
    end)
  end

  defp plan_goods(state) do
    Enum.reduce(rows(state.snapshot.items), state, fn xero, state ->
      attrs = Mapper.good(xero, state.account_codes, state.tax_by_type)
      add_op(state, {:good, attrs})
    end)
  end

  defp plan_fixed_assets(state) do
    Enum.reduce(rows(state.snapshot.fixed_assets), state, fn xero, state ->
      case Mapper.fixed_asset(xero) do
        {:ok, attrs} -> add_op(state, {:assets, attrs})
        {:error, err} -> add_error(state, err)
      end
    end)
  end

  defp plan_invoices(state) do
    Enum.reduce(rows(state.snapshot.invoices), state, fn inv, state ->
      cond do
        not Mapper.importable_invoice?(inv) ->
          add_op(state, {:skip, :not_importable, inv})

        not Mapper.base_currency_ok?(inv, state.base) ->
          add_error(state, {:foreign_currency, inv["InvoiceNumber"]})

        true ->
          xero_id = to_string(inv["InvoiceID"] || inv["InvoiceId"] || "")
          type = inv["Type"]

          state =
            state
            |> Map.update!(:invoice_ids, &MapSet.put(&1, xero_id))
            |> put_in([:invoice_types, xero_id], type)

          kind = if type == "ACCPAY", do: :bills, else: :invoices
          add_op(state, {kind, inv})
      end
    end)
  end

  defp plan_notes(state) do
    Enum.reduce(rows(state.snapshot.credit_notes), state, fn note, state ->
      cond do
        not Mapper.importable_invoice?(note) ->
          add_op(state, {:skip, :not_importable, note})

        not Mapper.base_currency_ok?(note, state.base) ->
          add_error(state, {:foreign_currency, note["CreditNoteNumber"] || note["CreditNoteID"]})

        true ->
          state
          |> plan_allocations(note["Allocations"] || [], note["CreditNoteID"])
          |> add_op({:note, note})
      end
    end)
  end

  defp plan_allocations(state, allocations, source_id) do
    Enum.reduce(allocations, state, fn alloc, state ->
      invoice_id = get_in(alloc, ["Invoice", "InvoiceID"]) || alloc["InvoiceID"]
      invoice_id = invoice_id && to_string(invoice_id)

      if invoice_id && MapSet.member?(state.invoice_ids, invoice_id) do
        state
      else
        add_error(state, {:missing_allocation_target, source_id, invoice_id || "unknown"})
      end
    end)
  end

  defp plan_payments(state) do
    Enum.reduce(rows(state.snapshot.payments), state, fn pay, state ->
      cond do
        not Mapper.importable_invoice?(pay) ->
          add_op(state, {:skip, :not_importable, pay})

        true ->
          payment_id = to_string(pay["PaymentID"] || pay["PaymentId"] || "")

          invoice_id =
            get_in(pay, ["Invoice", "InvoiceID"]) || get_in(pay, ["Invoice", "InvoiceId"])

          invoice_id = invoice_id && to_string(invoice_id)

          cond do
            is_nil(invoice_id) or not MapSet.member?(state.invoice_ids, invoice_id) ->
              add_error(state, {:missing_allocation_target, payment_id, invoice_id || "unknown"})

            state.invoice_types[invoice_id] == "ACCPAY" ->
              add_op(state, {:payments, pay})

            true ->
              add_op(state, {:receipts, pay})
          end
      end
    end)
  end

  defp plan_journals(state) do
    Enum.reduce(rows(state.snapshot.manual_journals), state, fn journal, state ->
      if journal["Status"] in [nil, "POSTED", "AUTHORISED"] do
        add_op(state, {:journals, journal})
      else
        add_op(state, {:skip, :journal_status, journal})
      end
    end)
  end

  defp plan_bank(state) do
    state
    |> then(fn state ->
      Enum.reduce(rows(state.snapshot.bank_transactions), state, &plan_bank_txn(&2, &1))
    end)
    |> then(fn state ->
      Enum.reduce(rows(state.snapshot.bank_transfers), state, &plan_bank_transfer(&2, &1))
    end)
  end

  defp plan_bank_txn(state, txn) do
    cond do
      not bank_txn_importable?(txn) ->
        add_op(state, {:skip, :not_importable, txn})

      Map.has_key?(txn, "CurrencyCode") and not Mapper.base_currency_ok?(txn, state.base) ->
        add_error(
          state,
          {:foreign_currency, txn["BankTransactionNumber"] || txn["BankTransactionID"]}
        )

      txn["Type"] == "SPEND" ->
        add_op(state, {:payments, txn})

      txn["Type"] == "RECEIVE" ->
        add_op(state, {:receipts, txn})

      true ->
        add_op(state, {:skip, :bank_type, txn})
    end
  end

  defp plan_bank_transfer(state, xfer) do
    if Map.get(xfer, "Status") in [nil, "AUTHORISED", "PAID"] do
      add_op(state, {:journals, xfer})
    else
      add_op(state, {:skip, :not_importable, xfer})
    end
  end

  defp add_op(state, op), do: %{state | ops: [op | state.ops]}
  defp add_error(state, err), do: %{state | errors: [err | state.errors]}

  # Conversion invoices: InvoiceNumber starts with "CONV-" or Date == conversion Date.
  def conversion_invoice?(inv, conversion_date) when is_map(inv) do
    num = to_string(inv["InvoiceNumber"] || "")

    String.starts_with?(num, "CONV-") or
      dates_equal?(parse_date(inv["Date"]), parse_date(conversion_date))
  end

  defp ensure_company(snapshot, user, name, reset?) do
    case find_company(name, user) do
      nil ->
        create_company(snapshot, user, name)

      company ->
        cond do
          reset? ->
            case Sys.delete_company(company, user) do
              {:ok, _} -> create_company(snapshot, user, name)
              :not_authorise -> {:error, :not_authorise}
              {:error, _op, val, _so_far} -> {:error, val}
            end

          company_not_empty?(company) ->
            {:error, :company_not_empty}

          true ->
            {:ok, company}
        end
    end
  end

  defp find_company(name, user) do
    Repo.one(
      from c in Company,
        join: cu in CompanyUser,
        on: cu.company_id == c.id,
        where: c.name == ^name and cu.user_id == ^user.id,
        limit: 1
    )
  end

  defp company_not_empty?(company) do
    Repo.exists?(from t in Transaction, where: t.company_id == ^company.id) or
      Repo.exists?(from i in Invoice, where: i.company_id == ^company.id)
  end

  defp create_company(snapshot, user, name) do
    org = organisation(snapshot)

    attrs = %{
      name: name,
      country: "Malaysia",
      timezone: map_timezone(org["Timezone"]),
      closing_month: org["FinancialYearEndMonth"] || 12,
      closing_day: org["FinancialYearEndDay"] || 31
    }

    case Sys.create_company(attrs, user) do
      {:ok, company} -> {:ok, company}
      {:error, _op, val, _so_far} -> {:error, val}
    end
  end

  defp organisation(%{organisation: %{"Name" => _} = org}), do: org
  defp organisation(%{organisation: %{"Organisations" => [org | _]}}), do: org
  defp organisation(%{organisation: [org | _]}) when is_map(org), do: org
  defp organisation(%{organisation: org}) when is_map(org), do: org
  defp organisation(_), do: %{}

  defp map_timezone(tz) when tz in [nil, ""], do: "Asia/Kuala_Lumpur"

  defp map_timezone(tz) when is_binary(tz) do
    zones = Tzdata.zone_list()

    cond do
      tz in zones ->
        tz

      true ->
        down = String.downcase(tz)
        Enum.find(zones, &(String.downcase(&1) == down)) || "Asia/Kuala_Lumpur"
    end
  end

  defp map_timezone(_), do: "Asia/Kuala_Lumpur"

  defp import_accounts(ctx) do
    reduce_rows(rows(ctx.snapshot.accounts), ctx, &import_one_account/2)
  end

  defp import_one_account(xero, ctx) do
    xero_id = xero["AccountID"] || xero["AccountId"]
    xero_name = xero["Name"]
    xero_code = xero["Code"]

    with {:ok, account_type} <- Mapper.account_type(xero["Type"], ctx.overrides) do
      fc_name = control_target(xero_name, ctx.overrides)

      acc =
        Accounting.get_account_by_name(fc_name, ctx.company, ctx.user) ||
          if(fc_name != xero_name,
            do: Accounting.get_account_by_name(xero_name, ctx.company, ctx.user)
          )

      cond do
        acc ->
          {:ok, put_account(ctx, xero_id, xero_code, acc)}

        true ->
          attrs = %{"name" => xero_name, "account_type" => account_type}

          case seed_one("Accounts", attrs, ctx) do
            {:ok, acc} -> {:ok, put_account(ctx, xero_id, xero_code, acc)}
            {:error, _} = err -> err
          end
      end
    end
  end

  defp control_target(xero_name, overrides) do
    custom = get_in(overrides, ["control_accounts", xero_name])
    custom || Map.get(@default_control_accounts, xero_name) || xero_name
  end

  defp put_account(ctx, xero_id, xero_code, acc) do
    xero_id = to_string(xero_id)

    ctx =
      ctx
      |> put_in([:id_map, "account:" <> xero_id], acc.id)
      |> put_in([:account_names, xero_id], acc.name)

    if is_binary(xero_code) do
      put_in(ctx, [:accounts_by_code, xero_code], acc.name)
    else
      ctx
    end
  end

  defp import_tax_codes(ctx) do
    reduce_rows(rows(ctx.snapshot.tax_rates), ctx, &import_one_tax_rate/2)
  end

  defp import_one_tax_rate(rate, ctx) do
    xero_type = rate["TaxType"]

    rate
    |> Mapper.tax_codes()
    |> Enum.reduce_while({:ok, ctx}, fn code, {:ok, ctx} ->
      case upsert_tax_code(code, xero_type, ctx) do
        {:ok, ctx} -> {:cont, {:ok, ctx}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp upsert_tax_code(code, xero_type, ctx) do
    attrs = %{
      "code" => code.code,
      "tax_type" => code.tax_type,
      "rate" => code.rate,
      "descriptions" => code.descriptions,
      "account_name" => tax_account_name(code.tax_type)
    }

    case Accounting.get_tax_code_by_code(code.code, ctx.company, ctx.user) do
      %{code: _} = tc ->
        {:ok, put_tax(ctx, xero_type, tc)}

      nil ->
        case seed_one("TaxCodes", attrs, ctx) do
          {:ok, tc} -> {:ok, put_tax(ctx, xero_type, tc)}
          {:error, _} = err -> err
        end
    end
  end

  defp tax_account_name("Sales"), do: "Sales Tax Payable"
  defp tax_account_name("Purchase"), do: "Purchase Tax Receivable"

  defp put_tax(ctx, xero_type, tc) do
    list = Map.get(ctx.tax_by_type, xero_type, [])
    entry = %{tax_type: tc.tax_type, code: tc.code}
    %{ctx | tax_by_type: Map.put(ctx.tax_by_type, xero_type, list ++ [entry])}
  end

  defp import_contacts(ctx) do
    reduce_rows(rows(ctx.snapshot.contacts), ctx, &import_one_contact/2)
  end

  defp import_one_contact(xero, ctx) do
    attrs = Mapper.contact(xero)
    xero_id = xero["ContactID"] || xero["ContactId"]

    case Accounting.get_contact_by_name(attrs["name"], ctx.company, ctx.user) do
      %Contact{} = contact ->
        {:ok, put_id(ctx, "contact:" <> to_string(xero_id), contact.id)}

      nil ->
        attrs =
          uniquify_name(attrs, ctx, &Accounting.get_contact_by_name(&1, ctx.company, ctx.user))

        case seed_one("Contacts", attrs, ctx) do
          {:ok, contact} -> {:ok, put_id(ctx, "contact:" <> to_string(xero_id), contact.id)}
          {:error, _} = err -> err
        end
    end
  end

  defp import_goods(ctx) do
    reduce_rows(rows(ctx.snapshot.items), ctx, &import_one_good/2)
  end

  defp import_one_good(xero, ctx) do
    attrs =
      xero
      |> Mapper.good(ctx.accounts_by_code, ctx.tax_by_type)
      |> Map.put_new("sales_tax_code_name", "NoSTax")
      |> Map.put_new("purchase_tax_code_name", "NoPTax")

    xero_id = xero["ItemID"] || xero["ItemId"]
    code = xero["Code"]

    case Product.get_good_by_name(attrs["name"], ctx.company, ctx.user) do
      %{id: id} ->
        ctx
        |> remember_good(xero_id, id, code, attrs["name"])
        |> then(&ensure_packaging(attrs["name"], &1))

      nil ->
        case seed_one("Goods", attrs, ctx) do
          {:ok, good} ->
            ctx
            |> remember_good(xero_id, good.id, code, attrs["name"])
            |> then(&ensure_packaging(attrs["name"], &1))

          {:error, _} = err ->
            err
        end
    end
  end

  defp remember_good(ctx, xero_id, fc_id, code, name) do
    ctx
    |> put_id("good:" <> to_string(xero_id), fc_id)
    |> put_good_code(code, name)
    |> put_in([:goods_names, to_string(xero_id)], name)
  end

  defp put_good_code(ctx, code, name) when is_binary(code) and code != "" do
    put_in(ctx, [:goods_by_code, code], name)
  end

  defp put_good_code(ctx, _code, _name), do: ctx

  defp ensure_packaging(good_name, ctx) do
    good = Product.get_good_by_name(good_name, ctx.company, ctx.user)

    cond do
      is_nil(good) ->
        {:ok, ctx}

      not is_nil(good.package_id) ->
        {:ok, ctx}

      true ->
        attrs = %{
          "good_name" => good_name,
          "name" => good.unit || "unit",
          "unit_multiplier" => 1,
          "cost_per_package" => 0,
          "default" => true
        }

        case seed_one("GoodPackagings", attrs, ctx) do
          {:ok, _} -> {:ok, ctx}
          {:error, _} = err -> err
        end
    end
  end

  defp import_fixed_assets(ctx) do
    reduce_rows(rows(ctx.snapshot.fixed_assets), ctx, &import_one_asset/2)
  end

  defp import_one_asset(xero, ctx) do
    with {:ok, attrs} <- Mapper.fixed_asset(xero) do
      attrs = Map.merge(attrs, asset_account_names(xero, ctx))
      xero_id = xero["AssetId"] || xero["AssetID"]

      case Accounting.get_fixed_asset_by_name(attrs["name"], ctx.company, ctx.user) do
        %{id: id} ->
          {:ok, put_id(ctx, "asset:" <> to_string(xero_id), id)}

        nil ->
          case seed_one("FixedAssets", attrs, ctx) do
            {:ok, fa} ->
              ctx = put_id(ctx, "asset:" <> to_string(xero_id), fa.id)
              seed_depreciations(xero, fa, ctx)

            {:error, _} = err ->
              err
          end
      end
    end
  end

  defp asset_account_names(xero, ctx) do
    type = xero["AssetType"] || %{}

    %{
      "asset_ac_name" => name_for_xero_account(type["FixedAssetAccountId"], ctx),
      "cume_depre_ac_name" =>
        name_for_xero_account(type["AccumulatedDepreciationAccountId"], ctx),
      "depre_ac_name" => name_for_xero_account(type["DepreciationExpenseAccountId"], ctx),
      "disp_fund_ac_name" =>
        name_for_xero_account(type["DisposalAccountId"], ctx) ||
          get_in(ctx.overrides, ["disposal_account"]) ||
          "Gain on Disposal"
    }
  end

  defp name_for_xero_account(nil, _ctx), do: nil

  defp name_for_xero_account(xero_id, ctx) do
    Map.get(ctx.account_names, to_string(xero_id))
  end

  defp seed_depreciations(xero, fa, ctx) do
    history = xero["DepreciationHistory"] || []

    Enum.reduce_while(history, {:ok, ctx}, fn row, {:ok, ctx} ->
      attrs = %{
        "fixed_asset_name" => fa.name,
        "cost_basis" => row["CostLimit"] || xero["PurchasePrice"] || fa.pur_price,
        "depre_date" => row["DepreciationDate"],
        "amount" => row["DepreciationAmount"]
      }

      case seed_one("FixedAssetDepreciations", attrs, ctx) do
        {:ok, _} -> {:cont, {:ok, ctx}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp seed_one(kind, attrs, ctx) do
    attrs = stringify_keys(attrs)
    {cs, filled} = Seeding.fill_changeset(kind, attrs, ctx.company, ctx.user)

    cond do
      not cs.valid? ->
        {:error, cs}

      true ->
        case Seeding.seed(kind, [{cs, filled}], ctx.company, ctx.user) do
          {:ok, _} -> {:ok, lookup_seeded(kind, filled, ctx)}
          :not_authorise -> {:error, :not_authorise}
          {:error, _} = err -> err
        end
    end
  end

  defp lookup_seeded("Accounts", filled, ctx),
    do: Accounting.get_account_by_name(filled["name"], ctx.company, ctx.user)

  defp lookup_seeded("TaxCodes", filled, ctx),
    do: Accounting.get_tax_code_by_code(filled["code"], ctx.company, ctx.user)

  defp lookup_seeded("Contacts", filled, ctx),
    do: Accounting.get_contact_by_name(filled["name"], ctx.company, ctx.user)

  defp lookup_seeded("Goods", filled, ctx),
    do: Product.get_good_by_name(filled["name"], ctx.company, ctx.user)

  defp lookup_seeded("FixedAssets", filled, ctx),
    do: Accounting.get_fixed_asset_by_name(filled["name"], ctx.company, ctx.user)

  defp lookup_seeded("FixedAssetDepreciations", _filled, _ctx), do: :ok
  defp lookup_seeded("GoodPackagings", _filled, _ctx), do: :ok
  defp lookup_seeded("Balances", _filled, _ctx), do: :ok

  defp uniquify_name(%{"name" => name} = attrs, _ctx, lookup) do
    %{attrs | "name" => unique_name(name, lookup, 2)}
  end

  defp unique_name(name, lookup, n) do
    case lookup.(name) do
      nil -> name
      _ -> unique_name("#{base_name(name)} (#{n})", lookup, n + 1)
    end
  end

  defp base_name(name) do
    String.replace(name, ~r/ \(\d+\)$/, "")
  end

  defp put_id(ctx, key, id), do: put_in(ctx, [:id_map, key], id)

  defp reduce_rows(rows, ctx, fun) do
    Enum.reduce_while(rows, {:ok, ctx}, fn row, {:ok, ctx} ->
      case fun.(row, ctx) do
        {:ok, ctx} -> {:cont, {:ok, ctx}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp rows(nil), do: []
  defp rows(list) when is_list(list), do: list

  defp rows(%{} = map) do
    map
    |> Map.values()
    |> Enum.find([], &is_list/1)
  end

  defp rows(_), do: []

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp seed_conversion_balances(ctx) do
    cb = ctx.snapshot.conversion_balances || %{}
    date = parse_date(cb["Date"]) || ~D[1970-01-01]
    {ar_strip, ap_strip} = conversion_control_strips(ctx)
    lines = cb["Lines"] || []

    Enum.reduce_while(lines, {:ok, ctx}, fn line, {:ok, ctx} ->
      case seed_conversion_line(line, date, ar_strip, ap_strip, ctx) do
        {:ok, ctx} -> {:cont, {:ok, ctx}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp conversion_control_strips(ctx) do
    date = conversion_date(ctx)

    rows(ctx.snapshot.invoices)
    |> Enum.filter(&Mapper.importable_invoice?/1)
    |> Enum.filter(&conversion_invoice?(&1, date))
    |> Enum.reduce({Decimal.new(0), Decimal.new(0)}, fn inv, {ar, ap} ->
      total = decimalize(inv["Total"] || 0)

      case inv["Type"] do
        "ACCPAY" -> {ar, Decimal.add(ap, total)}
        _ -> {Decimal.add(ar, total), ap}
      end
    end)
  end

  defp seed_conversion_line(line, date, ar_strip, ap_strip, ctx) do
    xero_id = to_string(line["AccountID"] || "")

    case name_for_xero_account(xero_id, ctx) do
      nil ->
        {:error, {:unmapped_account, xero_id}}

      name ->
        amount = decimalize(line["Balance"] || 0)

        amount =
          cond do
            ar_account?(name) -> Decimal.sub(amount, ar_strip)
            ap_account?(name) -> Decimal.sub(amount, ap_strip)
            true -> amount
          end

        if Decimal.eq?(amount, 0) do
          {:ok, ctx}
        else
          attrs = %{
            "account_name" => name,
            "amount" => amount,
            "doc_date" => date
          }

          case seed_one("Balances", attrs, ctx) do
            {:ok, _} -> {:ok, ctx}
            {:error, _} = err -> err
          end
        end
    end
  end

  defp ar_account?(name), do: name in ["Account Receivables", "Accounts Receivable"]
  defp ap_account?(name), do: name in ["Account Payables", "Accounts Payable"]

  defp conversion_date(ctx) do
    parse_date(get_in(ctx.snapshot.conversion_balances || %{}, ["Date"]))
  end

  defp import_invoices_and_bills(ctx) do
    base = base_currency(ctx)

    rows(ctx.snapshot.invoices)
    |> Enum.sort_by(&sort_date/1, Date)
    |> then(&reduce_rows(&1, ctx, fn inv, ctx -> import_one_invoice(inv, ctx, base) end))
  end

  defp import_one_invoice(inv, ctx, base) do
    cond do
      not Mapper.importable_invoice?(inv) ->
        {:ok, ctx}

      not Mapper.base_currency_ok?(inv, base) ->
        {:error, {:foreign_currency, inv["InvoiceNumber"]}}

      true ->
        persist_invoice(inv, ctx)
    end
  end

  defp persist_invoice(inv, ctx) do
    with {:ok, attrs, type} <- invoice_attrs(inv, ctx) do
      xero_id = to_string(inv["InvoiceID"] || inv["InvoiceId"])
      number = inv["InvoiceNumber"]

      result =
        case type do
          :pur_invoice -> Billing.import_pur_invoice(attrs, ctx.company, ctx.user)
          :invoice -> Billing.import_invoice(attrs, ctx.company, ctx.user)
        end

      case wrap_import(result) do
        {:ok, map} ->
          entity =
            Map.fetch!(
              map,
              if(type == :pur_invoice, do: :create_pur_invoice, else: :create_invoice)
            )

          doc_type = if(type == :pur_invoice, do: "PurInvoice", else: "Invoice")
          gap_type = if(type == :pur_invoice, do: :PurInvoice, else: :Invoice)

          ctx =
            ctx
            |> put_id("invoice:" <> xero_id, entity.id)
            |> put_invoice_info(xero_id, inv, entity, doc_type)
            |> track_number(gap_type, number)

          {:ok, ctx}

        {:error, _} = err ->
          err
      end
    end
  end

  defp invoice_attrs(inv, ctx) do
    type = if inv["Type"] == "ACCPAY", do: :pur_invoice, else: :invoice
    side = if type == :pur_invoice, do: "Purchase", else: "Sales"

    with {:ok, contact} <- mapped_contact(inv, ctx),
         {:ok, details} <- invoice_details(inv, ctx, side, type) do
      date = parse_date(inv["Date"]) || Date.utc_today()
      due = parse_date(inv["DueDate"]) || date
      number = inv["InvoiceNumber"]

      attrs =
        if type == :pur_invoice do
          %{
            "pur_invoice_no" => number,
            "pur_invoice_date" => date,
            "due_date" => due,
            "contact_id" => contact.id,
            "contact_name" => contact.name,
            "descriptions" => inv["Reference"] || number,
            "e_inv_internal_id" => number,
            "pur_invoice_details" => details
          }
        else
          %{
            "invoice_no" => number,
            "invoice_date" => date,
            "due_date" => due,
            "contact_id" => contact.id,
            "contact_name" => contact.name,
            "descriptions" => inv["Reference"] || number,
            "invoice_details" => details
          }
        end

      {:ok, attrs, type}
    end
  end

  defp invoice_details(inv, ctx, side, type) do
    (inv["LineItems"] || [])
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, fn {line, idx}, {:ok, acc} ->
      case invoice_detail(line, ctx, side, type, idx) do
        {:ok, detail} -> {:cont, {:ok, Map.put(acc, Integer.to_string(idx), detail)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp invoice_detail(line, ctx, side, type, idx) do
    with {:ok, good} <- resolve_line_good(line, ctx),
         {:ok, account} <- resolve_line_account(line, good, ctx, type),
         {:ok, tax} <- resolve_line_tax(line, ctx, side) do
      qty = decimalize(line["Quantity"] || 1)

      qty =
        if Decimal.compare(qty, 0) != :gt do
          Decimal.new(1)
        else
          qty
        end

      unit_price = decimalize(line["UnitAmount"] || line["LineAmount"] || 0)
      pkg_name = good.package_name || good.unit || "unit"

      {:ok,
       %{
         "good_id" => good.id,
         "good_name" => good_display_name(good),
         "account_id" => account.id,
         "account_name" => account.name,
         "tax_code_id" => tax.id,
         "tax_code_name" => tax.code,
         "package_id" => good.package_id,
         "package_name" => pkg_name,
         "quantity" => qty,
         "unit_price" => unit_price,
         "discount" => "0",
         "tax_rate" => tax.rate || Decimal.new(0),
         "unit_multiplier" => "0",
         "descriptions" => line["Description"],
         "_persistent_id" => Integer.to_string(idx + 1)
       }}
    end
  end

  defp resolve_line_good(line, ctx) do
    item_id =
      line["ItemID"] || get_in(line, ["Item", "ItemID"]) || get_in(line, ["Item", "ItemId"])

    item_code = line["ItemCode"]

    cond do
      is_binary(item_id) and Map.has_key?(ctx.id_map, "good:" <> to_string(item_id)) ->
        ensure_named_good(good_name_for_item_id(item_id, ctx), ctx)

      is_binary(item_code) and Map.has_key?(ctx.goods_by_code, item_code) ->
        ensure_named_good(ctx.goods_by_code[item_code], ctx)

      is_binary(item_code) and item_code != "" ->
        ensure_named_good(item_code, ctx)

      true ->
        ensure_named_good(@xero_line_good, ctx)
    end
  end

  defp good_name_for_item_id(item_id, ctx) do
    xero_id = to_string(item_id)

    case Map.get(ctx.goods_names, xero_id) do
      name when is_binary(name) ->
        name

      _ ->
        fc_id = ctx.id_map["good:" <> xero_id]
        Product.get_good!(fc_id, ctx.company, ctx.user).name
    end
  end

  defp ensure_named_good(name, ctx) do
    case Product.get_good_by_name(name, ctx.company, ctx.user) do
      %{id: _} = good ->
        case ensure_packaging(name, ctx) do
          {:ok, _} -> {:ok, Product.get_good_by_name(name, ctx.company, ctx.user) || good}
          {:error, _} = err -> err
        end

      nil ->
        sales = fallback_account_name(ctx)

        attrs = %{
          "name" => name,
          "unit" => "unit",
          "sales_account_name" => sales,
          "purchase_account_name" => sales,
          "sales_tax_code_name" => "NoSTax",
          "purchase_tax_code_name" => "NoPTax"
        }

        case seed_one("Goods", attrs, ctx) do
          {:ok, _} ->
            case ensure_packaging(name, ctx) do
              {:ok, _} ->
                {:ok, Product.get_good_by_name(name, ctx.company, ctx.user)}

              {:error, _} = err ->
                err
            end

          {:error, _} = err ->
            err
        end
    end
  end

  defp fallback_account_name(ctx) do
    Map.get(ctx.accounts_by_code, "200") ||
      ctx.account_names |> Map.values() |> List.first() ||
      "Sales"
  end

  defp resolve_line_account(line, good, ctx, type) do
    name =
      cond do
        is_binary(line["AccountCode"]) and Map.has_key?(ctx.accounts_by_code, line["AccountCode"]) ->
          ctx.accounts_by_code[line["AccountCode"]]

        type == :pur_invoice ->
          good.purchase_account_name

        true ->
          good.sales_account_name
      end

    case Accounting.get_account_by_name(name, ctx.company, ctx.user) do
      %{id: _} = acc -> {:ok, acc}
      nil -> {:error, {:unmapped_account, line["AccountCode"] || name}}
    end
  end

  defp resolve_line_tax(line, ctx, side) do
    name = tax_code_name(ctx, line["TaxType"], side)

    case Accounting.get_tax_code_by_code(name, ctx.company, ctx.user) do
      %{id: _} = tc -> {:ok, tc}
      nil -> {:error, {:unmapped_tax, line["TaxType"] || name}}
    end
  end

  defp tax_code_name(ctx, xero_type, side) do
    fallback = if(side == "Purchase", do: "NoPTax", else: "NoSTax")

    ctx.tax_by_type
    |> Map.get(xero_type, [])
    |> Enum.find(fn
      %{tax_type: ^side} -> true
      %{"tax_type" => ^side} -> true
      _ -> false
    end)
    |> case do
      %{code: c} -> c
      %{"code" => c} -> c
      _ -> fallback
    end
  end

  defp mapped_contact(doc, ctx) do
    xero_id = get_in(doc, ["Contact", "ContactID"]) || get_in(doc, ["Contact", "ContactId"])
    fc_id = xero_id && ctx.id_map["contact:" <> to_string(xero_id)]

    cond do
      is_nil(fc_id) ->
        {:error, {:unmapped_contact, xero_id}}

      true ->
        case Repo.get(Contact, fc_id) do
          %Contact{} = c -> {:ok, c}
          nil -> {:error, {:unmapped_contact, xero_id}}
        end
    end
  end

  defp put_invoice_info(ctx, xero_id, inv, entity, doc_type) do
    contact_id = Map.get(entity, :contact_id)
    number = inv["InvoiceNumber"]

    info = %{
      type: inv["Type"],
      number: number,
      contact_id: contact_id,
      contact_name: contact_name(contact_id),
      doc_type: doc_type
    }

    put_in(ctx, [:invoice_info, xero_id], info)
  end

  defp contact_name(nil), do: nil

  defp contact_name(id) do
    case Repo.get(Contact, id) do
      %Contact{name: name} -> name
      _ -> nil
    end
  end

  defp import_notes(ctx) do
    base = base_currency(ctx)

    reduce_rows(rows(ctx.snapshot.credit_notes), ctx, fn note, ctx ->
      import_one_note(note, ctx, base)
    end)
  end

  defp import_one_note(note, ctx, base) do
    cond do
      not Mapper.importable_invoice?(note) ->
        {:ok, ctx}

      not Mapper.base_currency_ok?(note, base) ->
        {:error, {:foreign_currency, note["CreditNoteNumber"] || note["CreditNoteID"]}}

      true ->
        persist_note(note, ctx)
    end
  end

  defp persist_note(note, ctx) do
    with :ok <- assert_note_allocations(note, ctx),
         {:ok, attrs, kind} <- note_attrs(note, ctx) do
      number = note["CreditNoteNumber"] || note["CreditNoteID"]

      result =
        case kind do
          :debit_note -> DebCre.import_debit_note(attrs, ctx.company, ctx.user)
          :credit_note -> DebCre.import_credit_note(attrs, ctx.company, ctx.user)
        end

      case wrap_import(result) do
        {:ok, _} ->
          gap = if(kind == :debit_note, do: :DebitNote, else: :CreditNote)
          {:ok, track_number(ctx, gap, number)}

        {:error, _} = err ->
          err
      end
    end
  end

  defp assert_note_allocations(note, ctx) do
    Enum.reduce_while(note["Allocations"] || [], :ok, fn alloc, :ok ->
      invoice_id = get_in(alloc, ["Invoice", "InvoiceID"]) || alloc["InvoiceID"]

      if invoice_id && Map.has_key?(ctx.id_map, "invoice:" <> to_string(invoice_id)) do
        {:cont, :ok}
      else
        {:halt, {:error, {:missing_allocation_target, note["CreditNoteID"], invoice_id}}}
      end
    end)
  end

  defp note_attrs(note, ctx) do
    kind = if note["Type"] == "ACCPAYCREDIT", do: :debit_note, else: :credit_note
    side = if kind == :debit_note, do: "Purchase", else: "Sales"
    details_key = if kind == :debit_note, do: "debit_note_details", else: "credit_note_details"

    with {:ok, contact} <- mapped_contact(note, ctx) do
      details =
        (note["LineItems"] || [])
        |> Enum.with_index()
        |> Map.new(fn {line, idx} ->
          tax_name = tax_code_name(ctx, line["TaxType"], side)
          tax = Accounting.get_tax_code_by_code(tax_name, ctx.company, ctx.user)
          acc_name = ctx.accounts_by_code[line["AccountCode"]] || fallback_account_name(ctx)
          acc = Accounting.get_account_by_name(acc_name, ctx.company, ctx.user)
          qty = decimalize(line["Quantity"] || 1)
          qty = if Decimal.compare(qty, 0) != :gt, do: Decimal.new(1), else: qty

          {Integer.to_string(idx),
           %{
             "descriptions" => line["Description"] || note["CreditNoteNumber"] || "Note",
             "account_id" => acc && acc.id,
             "account_name" => acc && acc.name,
             "tax_code_id" => tax && tax.id,
             "tax_code_name" => tax && tax.code,
             "quantity" => qty,
             "unit_price" => decimalize(line["UnitAmount"] || line["LineAmount"] || 0),
             "tax_rate" => (tax && tax.rate) || Decimal.new(0),
             "_persistent_id" => Integer.to_string(idx + 1)
           }}
        end)

      date = parse_date(note["Date"]) || Date.utc_today()

      with {:ok, matchers} <- note_matchers(note, ctx, kind, date) do
        attrs = %{
          "note_no" => note["CreditNoteNumber"] || note["CreditNoteID"],
          "note_date" => date,
          "contact_id" => contact.id,
          "contact_name" => contact.name,
          details_key => details,
          "transaction_matchers" => matchers
        }

        {:ok, attrs, kind}
      end
    end
  end

  defp note_matchers(note, ctx, kind, date) do
    doc_type = if(kind == :debit_note, do: "DebitNote", else: "CreditNote")

    (note["Allocations"] || [])
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, fn {alloc, idx}, {:ok, acc} ->
      invoice_id =
        get_in(alloc, ["Invoice", "InvoiceID"]) || get_in(alloc, ["Invoice", "InvoiceId"]) ||
          alloc["InvoiceID"]

      invoice_id = invoice_id && to_string(invoice_id)
      info = invoice_id && Map.get(ctx.invoice_info, invoice_id)
      amount = decimalize(alloc["Amount"] || 0)

      case info && control_transaction(info, ctx) do
        {:ok, txn} ->
          matcher = %{
            "transaction_id" => txn.id,
            "match_amount" => signed_match_amount(txn.amount, amount),
            "doc_type" => doc_type,
            "doc_date" => date,
            "t_doc_no" => info.number,
            "_persistent_id" => Integer.to_string(idx + 1)
          }

          {:cont, {:ok, Map.put(acc, Integer.to_string(idx), matcher)}}

        _ ->
          {:halt, {:error, {:missing_allocation_target, note["CreditNoteID"], invoice_id}}}
      end
    end)
  end

  defp import_receipts_and_payments(ctx) do
    reduce_rows(rows(ctx.snapshot.payments), ctx, &import_one_payment/2)
  end

  defp import_one_payment(pay, ctx) do
    cond do
      not Mapper.importable_invoice?(pay) ->
        {:ok, ctx}

      true ->
        persist_payment(pay, ctx)
    end
  end

  defp persist_payment(pay, ctx) do
    payment_id = to_string(pay["PaymentID"] || pay["PaymentId"])
    invoice_id = get_in(pay, ["Invoice", "InvoiceID"]) || get_in(pay, ["Invoice", "InvoiceId"])
    invoice_id = invoice_id && to_string(invoice_id)

    info = invoice_id && Map.get(ctx.invoice_info, invoice_id)

    cond do
      is_nil(invoice_id) or is_nil(info) or not Map.has_key?(ctx.id_map, "invoice:" <> invoice_id) ->
        {:error, {:missing_allocation_target, payment_id, invoice_id || "unknown"}}

      true ->
        apply_allocation(pay, payment_id, info, ctx)
    end
  end

  defp apply_allocation(pay, payment_id, info, ctx) do
    with {:ok, txn} <- control_transaction(info, ctx),
         {:ok, funds} <- payment_funds_account(pay, ctx) do
      date = parse_date(pay["Date"]) || Date.utc_today()
      amount = decimalize(pay["Amount"] || 0)
      match_amount = signed_match_amount(txn.amount, amount)
      number = pay["PaymentNumber"] || pay["Reference"] || payment_id

      matcher = %{
        "0" => %{
          "transaction_id" => txn.id,
          "match_amount" => match_amount,
          "doc_type" => if(info.type == "ACCPAY", do: "Payment", else: "Receipt"),
          "doc_date" => date,
          "t_doc_no" => info.number,
          "_persistent_id" => "1"
        }
      }

      if info.type == "ACCPAY" do
        attrs = %{
          "payment_no" => number,
          "payment_date" => date,
          "contact_id" => info.contact_id,
          "contact_name" => info.contact_name,
          "funds_account_id" => funds.id,
          "funds_account_name" => funds.name,
          "funds_amount" => amount,
          "payment_details" => %{},
          "transaction_matchers" => matcher
        }

        case wrap_import(BillPay.import_payment(attrs, ctx.company, ctx.user)) do
          {:ok, _} -> {:ok, track_number(ctx, :Payment, number)}
          {:error, _} = err -> err
        end
      else
        attrs = %{
          "receipt_no" => number,
          "receipt_date" => date,
          "contact_id" => info.contact_id,
          "contact_name" => info.contact_name,
          "funds_account_id" => funds.id,
          "funds_account_name" => funds.name,
          "funds_amount" => amount,
          "receipt_details" => %{},
          "transaction_matchers" => matcher
        }

        case wrap_import(ReceiveFund.import_receipt(attrs, ctx.company, ctx.user)) do
          {:ok, _} -> {:ok, track_number(ctx, :Receipt, number)}
          {:error, _} = err -> err
        end
      end
    end
  end

  defp control_transaction(info, ctx) do
    account_name =
      if info.type == "ACCPAY", do: "Account Payables", else: "Account Receivables"

    txn =
      Repo.one(
        from t in Transaction,
          join: a in FullCircle.Accounting.Account,
          on: a.id == t.account_id,
          where:
            t.company_id == ^ctx.company.id and t.doc_no == ^info.number and
              t.doc_type == ^info.doc_type and a.name == ^account_name
      )

    if txn, do: {:ok, txn}, else: {:error, {:missing_allocation_target, info.number, info.number}}
  end

  defp payment_funds_account(pay, ctx) do
    xero_id =
      get_in(pay, ["Account", "AccountID"]) ||
        get_in(pay, ["Account", "AccountId"]) ||
        pay["AccountID"]

    name = name_for_xero_account(xero_id, ctx)

    case name && Accounting.get_account_by_name(name, ctx.company, ctx.user) do
      %{id: _} = acc -> {:ok, acc}
      _ -> {:error, {:unmapped_account, xero_id}}
    end
  end

  defp import_journals(ctx) do
    reduce_rows(rows(ctx.snapshot.manual_journals), ctx, &import_one_journal/2)
  end

  defp import_one_journal(journal, ctx) do
    status = journal["Status"]

    if status in [nil, "POSTED", "AUTHORISED"] do
      persist_journal(journal, ctx)
    else
      {:ok, ctx}
    end
  end

  defp persist_journal(journal, ctx) do
    number = journal["JournalNumber"] || journal["ManualJournalID"] || journal["Narration"]
    date = parse_date(journal["Date"]) || Date.utc_today()
    lines = journal["JournalLines"] || journal["Lines"] || []

    transactions =
      lines
      |> Enum.with_index()
      |> Map.new(fn {line, idx} ->
        acc_name =
          ctx.accounts_by_code[line["AccountCode"]] ||
            name_for_xero_account(line["AccountID"], ctx)

        acc = acc_name && Accounting.get_account_by_name(acc_name, ctx.company, ctx.user)

        {Integer.to_string(idx),
         %{
           "account_id" => acc && acc.id,
           "account_name" => acc && acc.name,
           "particulars" => line["Description"] || journal["Narration"] || number,
           "amount" => decimalize(line["LineAmount"] || 0),
           "_persistent_id" => Integer.to_string(idx)
         }}
      end)

    attrs = %{
      "journal_no" => number,
      "journal_date" => date,
      "transactions" => transactions
    }

    case wrap_import(JournalEntry.import_journal(attrs, ctx.company, ctx.user)) do
      {:ok, _} -> {:ok, track_number(ctx, :Journal, number)}
      {:error, _} = err -> err
    end
  end

  defp signed_match_amount(header_amount, alloc_amount) do
    abs_alloc = Decimal.abs(decimalize(alloc_amount))

    if Decimal.lt?(header_amount, Decimal.new(0)) do
      abs_alloc
    else
      Decimal.negate(abs_alloc)
    end
  end

  defp import_bank(ctx) do
    with {:ok, ctx} <-
           reduce_rows(rows(ctx.snapshot.bank_transactions), ctx, &import_one_bank_txn/2) do
      reduce_rows(rows(ctx.snapshot.bank_transfers), ctx, &import_one_bank_transfer/2)
    end
  end

  defp import_one_bank_txn(txn, ctx) do
    cond do
      not bank_txn_importable?(txn) ->
        {:ok, ctx}

      Map.has_key?(txn, "CurrencyCode") and not Mapper.base_currency_ok?(txn, base_currency(ctx)) ->
        {:error, {:foreign_currency, txn["BankTransactionNumber"] || txn["BankTransactionID"]}}

      txn["Type"] == "SPEND" ->
        persist_bank_spend(txn, ctx)

      txn["Type"] == "RECEIVE" ->
        persist_bank_receive(txn, ctx)

      true ->
        {:ok, ctx}
    end
  end

  defp bank_txn_importable?(txn) do
    Map.get(txn, "Status") in [nil, "AUTHORISED", "PAID"]
  end

  defp persist_bank_spend(txn, ctx) do
    with {:ok, contact} <- mapped_contact(txn, ctx),
         {:ok, funds} <- bank_txn_funds_account(txn, ctx),
         {:ok, details} <- invoice_details(txn, ctx, "Purchase", :pur_invoice) do
      date = parse_date(txn["Date"]) || Date.utc_today()
      number = txn["BankTransactionNumber"] || txn["BankTransactionID"]
      amount = bank_txn_amount(txn)

      attrs = %{
        "payment_no" => number,
        "payment_date" => date,
        "contact_id" => contact.id,
        "contact_name" => contact.name,
        "funds_account_id" => funds.id,
        "funds_account_name" => funds.name,
        "funds_amount" => amount,
        "descriptions" => txn["Reference"] || txn["Narration"],
        "payment_details" => details,
        "transaction_matchers" => %{}
      }

      case wrap_import(BillPay.import_payment(attrs, ctx.company, ctx.user)) do
        {:ok, _} -> {:ok, track_number(ctx, :Payment, number)}
        {:error, _} = err -> err
      end
    end
  end

  defp persist_bank_receive(txn, ctx) do
    with {:ok, contact} <- mapped_contact(txn, ctx),
         {:ok, funds} <- bank_txn_funds_account(txn, ctx),
         {:ok, details} <- invoice_details(txn, ctx, "Sales", :invoice) do
      date = parse_date(txn["Date"]) || Date.utc_today()
      number = txn["BankTransactionNumber"] || txn["BankTransactionID"]
      amount = bank_txn_amount(txn)

      attrs = %{
        "receipt_no" => number,
        "receipt_date" => date,
        "contact_id" => contact.id,
        "contact_name" => contact.name,
        "funds_account_id" => funds.id,
        "funds_account_name" => funds.name,
        "funds_amount" => amount,
        "descriptions" => txn["Reference"] || txn["Narration"],
        "receipt_details" => details,
        "transaction_matchers" => %{}
      }

      case wrap_import(ReceiveFund.import_receipt(attrs, ctx.company, ctx.user)) do
        {:ok, _} -> {:ok, track_number(ctx, :Receipt, number)}
        {:error, _} = err -> err
      end
    end
  end

  defp bank_txn_funds_account(txn, ctx) do
    xero_id =
      get_in(txn, ["BankAccount", "AccountID"]) ||
        get_in(txn, ["BankAccount", "AccountId"]) ||
        txn["AccountID"]

    name = name_for_xero_account(xero_id, ctx)

    case name && Accounting.get_account_by_name(name, ctx.company, ctx.user) do
      %{id: _} = acc -> {:ok, acc}
      _ -> {:error, {:unmapped_account, xero_id}}
    end
  end

  defp bank_txn_amount(txn) do
    case decimalize(txn["Total"] || txn["TotalAmount"]) do
      %Decimal{} = d ->
        if Decimal.eq?(d, 0) do
          (txn["LineItems"] || [])
          |> Enum.reduce(Decimal.new(0), fn line, acc ->
            Decimal.add(acc, decimalize(line["LineAmount"] || line["UnitAmount"] || 0))
          end)
        else
          d
        end
    end
  end

  defp import_one_bank_transfer(xfer, ctx) do
    status = Map.get(xfer, "Status")

    if status in [nil, "AUTHORISED", "PAID"] do
      persist_bank_transfer(xfer, ctx)
    else
      {:ok, ctx}
    end
  end

  defp persist_bank_transfer(xfer, ctx) do
    from_id =
      get_in(xfer, ["FromBankAccount", "AccountID"]) ||
        get_in(xfer, ["FromBankAccount", "AccountId"])

    to_id =
      get_in(xfer, ["ToBankAccount", "AccountID"]) ||
        get_in(xfer, ["ToBankAccount", "AccountId"])

    from_name = name_for_xero_account(from_id, ctx)
    to_name = name_for_xero_account(to_id, ctx)
    from_acc = from_name && Accounting.get_account_by_name(from_name, ctx.company, ctx.user)
    to_acc = to_name && Accounting.get_account_by_name(to_name, ctx.company, ctx.user)

    cond do
      is_nil(from_acc) ->
        {:error, {:unmapped_account, from_id}}

      is_nil(to_acc) ->
        {:error, {:unmapped_account, to_id}}

      true ->
        number = xfer["BankTransferID"] || xfer["Reference"]
        date = parse_date(xfer["Date"]) || Date.utc_today()
        amount = decimalize(xfer["Amount"] || 0)
        particulars = xfer["Reference"] || "Bank transfer"

        attrs = %{
          "journal_no" => number,
          "journal_date" => date,
          "transactions" => %{
            "0" => %{
              "account_id" => to_acc.id,
              "account_name" => to_acc.name,
              "particulars" => particulars,
              "amount" => amount,
              "_persistent_id" => "0"
            },
            "1" => %{
              "account_id" => from_acc.id,
              "account_name" => from_acc.name,
              "particulars" => particulars,
              "amount" => Decimal.negate(amount),
              "_persistent_id" => "1"
            }
          }
        }

        case wrap_import(JournalEntry.import_journal(attrs, ctx.company, ctx.user)) do
          {:ok, _} -> {:ok, track_number(ctx, :Journal, number)}
          {:error, _} = err -> err
        end
    end
  end

  defp wrap_import({:ok, result}), do: {:ok, result}
  defp wrap_import(:not_authorise), do: {:error, :not_authorise}
  defp wrap_import({:error, _op, val, _so_far}), do: {:error, val}
  defp wrap_import({:error, _} = err), do: err
  defp wrap_import(other), do: {:error, other}

  defp track_number(ctx, type, number) when is_binary(number) do
    update_in(ctx, [:imported_numbers, type], fn list -> (list || []) ++ [number] end)
  end

  defp track_number(ctx, _type, _number), do: ctx

  defp good_display_name(%{value: name}) when is_binary(name), do: name
  defp good_display_name(%{name: name}) when is_binary(name), do: name
  defp good_display_name(_), do: "Xero Line"

  defp base_currency(ctx) do
    organisation(ctx.snapshot)["BaseCurrency"] || "MYR"
  end

  defp sort_date(row) do
    parse_date(row["Date"]) || ~D[0001-01-01]
  end

  defp dates_equal?(%Date{} = a, %Date{} = b), do: Date.compare(a, b) == :eq
  defp dates_equal?(_, _), do: false

  defp parse_date(nil), do: nil
  defp parse_date(%Date{} = d), do: d

  defp parse_date(
         <<y::binary-size(4), "-", m::binary-size(2), "-", d::binary-size(2), _::binary>>
       ) do
    case Date.from_iso8601("#{y}-#{m}-#{d}") do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(other) when is_binary(other) do
    case Date.from_iso8601(other) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp parse_date(_), do: nil

  defp decimalize(nil), do: Decimal.new(0)
  defp decimalize(%Decimal{} = d), do: d
  defp decimalize(n) when is_integer(n), do: Decimal.new(n)
  defp decimalize(n) when is_float(n), do: n |> to_string() |> Decimal.new()
  defp decimalize(bin) when is_binary(bin), do: Decimal.new(bin)
  defp decimalize(_), do: Decimal.new(0)
end
