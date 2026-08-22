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

  @xero_line_good "__xero_line__"
  @receive_bank_types ~w(RECEIVE RECEIVE-OVERPAYMENT RECEIVE-PREPAYMENT)
  @spend_bank_types ~w(SPEND SPEND-OVERPAYMENT SPEND-PREPAYMENT)

  def run(snapshot, user, opts \\ []) do
    # One transaction for the whole replay: a mid-import failure must not
    # strand a half-imported company with gapless counters still at zero.
    case Repo.transaction(fn -> run_inside(snapshot, user, opts) end, timeout: :infinity) do
      {:ok, {:ok, result}} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_inside(snapshot, user, opts) do
    case do_run(snapshot, user, opts) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> Repo.rollback(reason)
      other -> Repo.rollback(other)
    end
  end

  defp do_run(snapshot, user, opts) do
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
           number_seq: %{},
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
             {:ok, ctx} <- post_catchup_journals(ctx),
             {:ok, ctx} <- post_aged_attribution(ctx),
             {:ok, ctx} <- post_closing_journals(ctx),
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
      add_op(state, {:goods, attrs})
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
        Mapper.overpayment_or_prepayment?(inv) ->
          add_op(state, {:skip, :overpayment, inv})

        not Mapper.importable_invoice?(inv) ->
          add_op(state, {:skip, :not_importable, inv})

        zero_total?(inv) ->
          add_op(state, {:skip, :zero_total, inv})

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
          |> add_op({:notes, note})
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

        Mapper.overpayment_or_prepayment?(pay["Invoice"] || %{}) ->
          kind =
            if String.starts_with?(to_string(get_in(pay, ["Invoice", "Type"])), "AR"),
              do: :payments,
              else: :receipts

          add_op(state, {kind, pay})

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

      txn["Type"] in @spend_bank_types ->
        add_op(state, {:payments, txn})

      txn["Type"] in @receive_bank_types ->
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

  # Conversion invoices: InvoiceNumber starts with "CONV-" or Date is on or
  # before the conversion Date (Xero setup enters open invoices with their
  # original pre-conversion dates; they are part of the conversion AR/AP).
  def conversion_invoice?(inv, conversion_date) when is_map(inv) do
    num = to_string(inv["InvoiceNumber"] || "")

    String.starts_with?(num, "CONV-") or
      on_or_before?(parse_date(inv["Date"]), parse_date(conversion_date))
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
      Repo.exists?(from i in Invoice, where: i.company_id == ^company.id) or
      Repo.exists?(from c in Contact, where: c.company_id == ^company.id) or
      Repo.exists?(from g in FullCircle.Product.Good, where: g.company_id == ^company.id)
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
      fc_name = Mapper.control_account_name(xero_name, ctx.overrides)

      acc =
        Accounting.get_account_by_name(fc_name, ctx.company, ctx.user) ||
          if(fc_name != xero_name,
            do: Accounting.get_account_by_name(xero_name, ctx.company, ctx.user)
          )

      cond do
        acc ->
          {:ok, put_account(ctx, xero_id, xero_code, acc)}

        true ->
          attrs = %{"name" => fc_name, "account_type" => account_type}

          case seed_one("Accounts", attrs, ctx) do
            {:ok, acc} -> {:ok, put_account(ctx, xero_id, xero_code, acc)}
            {:error, _} = err -> err
          end
      end
    end
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
    if zero_rate?(code.rate) do
      default_code = if(code.tax_type == "Purchase", do: "NoPTax", else: "NoSTax")

      case Accounting.get_tax_code_by_code(default_code, ctx.company, ctx.user) do
        %{code: _} = tc -> {:ok, put_tax(ctx, xero_type, tc)}
        nil -> {:error, {:unmapped_tax, default_code}}
      end
    else
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
  end

  defp zero_rate?(rate) do
    Decimal.compare(decimalize(rate), Decimal.new(0)) == :eq
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

    attrs =
      uniquify_name(attrs, ctx, &Accounting.get_contact_by_name(&1, ctx.company, ctx.user))

    case seed_one("Contacts", attrs, ctx) do
      {:ok, contact} -> {:ok, put_id(ctx, "contact:" <> to_string(xero_id), contact.id)}
      {:error, _} = err -> err
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
      |> default_good_accounts(ctx)

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

  # Xero items may carry only one of SalesDetails/PurchaseDetails; Seeding
  # requires both account names, so default the missing side.
  defp default_good_accounts(attrs, ctx) do
    sales = attrs["sales_account_name"] || attrs["purchase_account_name"]
    purchase = attrs["purchase_account_name"] || attrs["sales_account_name"]
    fallback = fallback_account_name(ctx)

    attrs
    |> Map.put("sales_account_name", sales || fallback)
    |> Map.put("purchase_account_name", purchase || fallback)
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
    with {:ok, attrs} <- Mapper.fixed_asset(xero),
         attrs = Map.merge(attrs, asset_account_names(xero, ctx)),
         :ok <- ensure_disposal_account(attrs, ctx),
         :ok <- assert_asset_accounts(attrs) do
      xero_id = xero["AssetId"] || xero["AssetID"]

      attrs =
        uniquify_name(attrs, ctx, &Accounting.get_fixed_asset_by_name(&1, ctx.company, ctx.user))

      case seed_one("FixedAssets", attrs, ctx) do
        {:ok, fa} ->
          ctx = put_id(ctx, "asset:" <> to_string(xero_id), fa.id)
          seed_depreciations(xero, fa, attrs, ctx)

        {:error, _} = err ->
          err
      end
    end
  end

  defp assert_asset_accounts(attrs) do
    ["asset_ac_name", "cume_depre_ac_name", "depre_ac_name", "disp_fund_ac_name"]
    |> Enum.find(&is_nil(attrs[&1]))
    |> case do
      nil -> :ok
      missing -> {:error, {:unmapped_asset_account, attrs["name"], missing}}
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

  # Xero charts often have no disposal/gain account (fixed assets live in a
  # separate register); FC's FixedAsset requires one, so seed the fallback.
  defp ensure_disposal_account(%{"disp_fund_ac_name" => name}, ctx) when is_binary(name) do
    case Accounting.get_account_by_name(name, ctx.company, ctx.user) do
      %{id: _} ->
        :ok

      nil ->
        case seed_one("Accounts", %{"name" => name, "account_type" => "Other Income"}, ctx) do
          {:ok, _} -> :ok
          {:error, _} = err -> err
        end
    end
  end

  defp ensure_disposal_account(_attrs, _ctx), do: :ok

  defp name_for_xero_account(nil, _ctx), do: nil

  defp name_for_xero_account(xero_id, ctx) do
    Map.get(ctx.account_names, to_string(xero_id))
  end

  defp seed_depreciations(xero, fa, asset_attrs, ctx) do
    history =
      (xero["DepreciationHistory"] || [])
      |> Mapper.expand_depreciation_history(fa, ctx.company)

    conv_date = conversion_date(ctx)

    history
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, ctx}, fn {row, idx}, {:ok, ctx} ->
      attrs = %{
        "fixed_asset_name" => fa.name,
        "cost_basis" => row["CostLimit"] || xero["PurchasePrice"] || fa.pur_price,
        "depre_date" => row["DepreciationDate"],
        "amount" => row["DepreciationAmount"]
      }

      with {:ok, _} <- seed_one("FixedAssetDepreciations", attrs, ctx),
           {:ok, ctx} <- post_depreciation_journal(row, idx, xero, asset_attrs, conv_date, ctx) do
        {:cont, {:ok, ctx}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # Xero posts depreciation to the GL via system journals (Journals API,
  # not pulled). Reconstruct them from DepreciationHistory — but only for
  # rows after the conversion date: earlier depreciation already sits in the
  # conversion balances.
  defp post_depreciation_journal(row, idx, xero, asset_attrs, conv_date, ctx) do
    date = parse_date(row["DepreciationDate"])
    amount = decimalize(row["DepreciationAmount"] || 0)

    pre_conversion? = conv_date != nil and date != nil and Date.compare(date, conv_date) != :gt

    if pre_conversion? or Decimal.eq?(amount, 0) or is_nil(date) do
      {:ok, ctx}
    else
      depre = Accounting.get_account_by_name(asset_attrs["depre_ac_name"], ctx.company, ctx.user)

      accum =
        Accounting.get_account_by_name(asset_attrs["cume_depre_ac_name"], ctx.company, ctx.user)

      asset_ref = presence(xero["AssetNumber"]) || xero["AssetId"] || xero["AssetID"]
      number = "XDEP-#{asset_ref}-#{idx + 1}"
      particulars = "Depreciation #{asset_attrs["name"]}"

      attrs = %{
        "journal_no" => number,
        "journal_date" => date,
        "transactions" => %{
          "0" => %{
            "account_id" => depre && depre.id,
            "account_name" => depre && depre.name,
            "particulars" => particulars,
            "amount" => amount,
            "_persistent_id" => "0"
          },
          "1" => %{
            "account_id" => accum && accum.id,
            "account_name" => accum && accum.name,
            "particulars" => particulars,
            "amount" => Decimal.negate(amount),
            "_persistent_id" => "1"
          }
        }
      }

      case wrap_import(JournalEntry.import_journal(attrs, ctx.company, ctx.user)) do
        {:ok, _} -> {:ok, ctx}
        {:error, _} = err -> err
      end
    end
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

    lines
    |> Enum.reduce_while({:ok, ctx}, fn line, {:ok, ctx} ->
      case seed_conversion_line(line, date, ar_strip, ap_strip, ctx) do
        {:ok, ctx} -> {:cont, {:ok, ctx}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, ctx} when lines != [] ->
        balance_conversion_seed(date, ctx)

      other ->
        other
    end
  end

  # Xero's conversion set balances to zero, but the AR/AP strips displace the
  # part now re-posted by the imported conversion documents (whose P&L side
  # Xero folds into Retained Earnings). Re-balance the seed set with an RE
  # line so the ledger stays at zero.
  defp balance_conversion_seed(date, ctx) do
    seeded =
      Repo.one(
        from t in Transaction,
          where: t.company_id == ^ctx.company.id and t.old_data == true,
          select: coalesce(sum(t.amount), 0)
      )
      |> decimalize()

    if Decimal.eq?(seeded, 0) do
      {:ok, ctx}
    else
      with {:ok, re} <- retained_earnings_account(ctx) do
        attrs = %{
          "account_name" => re.name,
          "amount" => Decimal.negate(seeded),
          "doc_date" => date
        }

        case seed_one("Balances", attrs, ctx) do
          {:ok, _} -> {:ok, ctx}
          {:error, _} = err -> err
        end
      end
    end
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

        # Conversion balances are debit-positive: AR arrives positive, AP negative.
        # Impending conversion documents re-post AR positive / AP negative, so the
        # strip must move each balance toward zero from its own side.
        amount =
          cond do
            ar_account?(name) -> Decimal.sub(amount, ar_strip)
            ap_account?(name) -> Decimal.add(amount, ap_strip)
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
      Mapper.overpayment_or_prepayment?(inv) ->
        {:ok, ctx}

      not Mapper.importable_invoice?(inv) ->
        {:ok, ctx}

      # FC validates invoice_amount > 0, so zero-total invoices can't import
      # as invoices. All-zero lines carry no ledger effect and are dropped;
      # self-cancelling lines across different accounts (e.g. POS float
      # movements) still move per-account balances, so they become a journal.
      # Snapshot.doc_totals excludes zero-total docs, keeping counts aligned.
      zero_total?(inv) ->
        persist_zero_invoice_journal(inv, ctx)

      not Mapper.base_currency_ok?(inv, base) ->
        {:error, {:foreign_currency, inv["InvoiceNumber"]}}

      true ->
        persist_invoice(inv, ctx)
    end
  end

  defp zero_total?(doc) do
    Decimal.eq?(decimalize(doc["Total"] || 0), 0)
  end

  defp persist_zero_invoice_journal(inv, ctx) do
    lines =
      (inv["LineItems"] || [])
      |> Enum.reject(fn line -> Decimal.eq?(decimalize(line["LineAmount"] || 0), 0) end)

    if lines == [] do
      {:ok, ctx}
    else
      {number, ctx} = readable_number(invoice_number(inv), :Journal, ctx)
      date = parse_date(inv["Date"]) || Date.utc_today()

      # Xero GL semantics: an ACCREC line of +L CREDITS its account (sales
      # side), an ACCPAY line of +L DEBITS its account. Zero-total docs post
      # no AR/AP, but each line still needs its ledger sign.
      sign = if inv["Type"] == "ACCREC", do: Decimal.new("-1"), else: Decimal.new("1")

      transactions =
        lines
        |> Enum.with_index()
        |> Map.new(fn {line, idx} ->
          acc_name = ctx.accounts_by_code[line["AccountCode"]] || fallback_account_name(ctx)
          acc = Accounting.get_account_by_name(acc_name, ctx.company, ctx.user)

          {Integer.to_string(idx),
           %{
             "account_id" => acc && acc.id,
             "account_name" => acc && acc.name,
             "particulars" => presence(line["Description"]) || number,
             "amount" => Decimal.mult(decimalize(line["LineAmount"]), sign),
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
  end

  defp persist_invoice(inv, ctx) do
    type = if inv["Type"] == "ACCPAY", do: :pur_invoice, else: :invoice
    gap = if type == :pur_invoice, do: :PurInvoice, else: :Invoice
    {number, ctx} = readable_number(invoice_number(inv), gap, ctx)
    number = dedupe_doc_number(number, type, ctx)

    with {:ok, attrs, ^type} <- invoice_attrs(inv, ctx, number) do
      xero_id = to_string(inv["InvoiceID"] || inv["InvoiceId"])

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
            |> put_invoice_info(xero_id, inv, entity, doc_type, number)
            |> track_number(gap_type, number)

          {:ok, ctx}

        {:error, _} = err ->
          err
      end
    end
  end

  defp invoice_attrs(inv, ctx, number) do
    type = if inv["Type"] == "ACCPAY", do: :pur_invoice, else: :invoice
    side = if type == :pur_invoice, do: "Purchase", else: "Sales"

    with {:ok, contact} <- mapped_contact(inv, ctx),
         {:ok, details} <- invoice_details(inv, ctx, side, type),
         {:ok, details} <- align_doc_total(details, inv, number, side, ctx) do
      date = parse_date(inv["Date"]) || Date.utc_today()
      due = parse_date(inv["DueDate"]) || date

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

  # Xero's Total is the authoritative AR/AP posting and includes its own
  # rounding; FC recomputes from lines, so per-document cent gaps accumulate
  # into aged/total drift. Close each gap with an explicit rounding line.
  # A gap beyond 1.00 is a mapping bug, not rounding — fail loudly.
  @max_doc_rounding Decimal.new("1.00")

  defp align_doc_total(details, inv, number, side, ctx) do
    xero_total = decimalize(inv["Total"] || 0)

    computed =
      Enum.reduce(details, Decimal.new(0), fn {_k, d}, acc ->
        line =
          d["quantity"]
          |> decimalize()
          |> Decimal.mult(decimalize(d["unit_price"]))
          |> Decimal.add(decimalize(d["discount"]))
          |> then(&Decimal.mult(&1, Decimal.add(Decimal.new(1), decimalize(d["tax_rate"]))))

        Decimal.add(acc, line)
      end)

    delta = xero_total |> Decimal.sub(computed) |> Decimal.round(2)

    cond do
      Decimal.eq?(delta, 0) ->
        {:ok, details}

      Decimal.compare(Decimal.abs(delta), @max_doc_rounding) == :gt ->
        {:error, {:doc_total_mismatch, number, delta}}

      true ->
        with {:ok, good} <- ensure_named_good(@xero_line_good, ctx) do
          {_k, first} = Enum.min_by(details, fn {k, _} -> String.to_integer(k) end)
          idx = map_size(details)
          tax_code = if side == "Purchase", do: "NoPTax", else: "NoSTax"
          tax = Accounting.get_tax_code_by_code(tax_code, ctx.company, ctx.user)

          line = %{
            "good_id" => good.id,
            "good_name" => good_display_name(good),
            "account_id" => first["account_id"],
            "account_name" => first["account_name"],
            "tax_code_id" => tax && tax.id,
            "tax_code_name" => tax && tax.code,
            "package_id" => good.package_id,
            "package_name" => good.package_name || good.unit || "unit",
            # package_qty mirrors quantity: seeded packagings have
            # unit_multiplier 1 and the edit form recomputes
            # quantity = package_qty * multiplier.
            "quantity" => Decimal.new(1),
            "package_qty" => Decimal.new(1),
            "unit_price" => delta,
            "discount" => Decimal.new(0),
            "tax_rate" => Decimal.new(0),
            "unit_multiplier" => "0",
            "descriptions" => "Xero rounding",
            "_persistent_id" => Integer.to_string(idx + 1)
          }

          {:ok, Map.put(details, Integer.to_string(idx), line)}
        end
    end
  end

  defp invoice_details(inv, ctx, side, type) do
    line_types = inv["LineAmountTypes"]

    (inv["LineItems"] || [])
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, fn {line, idx}, {:ok, acc} ->
      case invoice_detail(line, ctx, side, type, idx, line_types) do
        {:ok, detail} -> {:cont, {:ok, Map.put(acc, Integer.to_string(idx), detail)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp invoice_detail(line, ctx, side, type, idx, line_types) do
    with {:ok, good} <- resolve_line_good(line, ctx),
         {:ok, account} <- resolve_line_account(line, good, ctx, type),
         {:ok, tax} <- resolve_line_tax(line, ctx, side) do
      {qty, unit_price, discount} = line_pricing(line, tax.rate, line_types)

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
         # package_qty mirrors quantity — see align_doc_total comment.
         "quantity" => qty,
         "package_qty" => qty,
         "unit_price" => unit_price,
         "discount" => discount,
         "tax_rate" => tax.rate || Decimal.new(0),
         "unit_multiplier" => "0",
         "descriptions" => line["Description"],
         "_persistent_id" => Integer.to_string(idx + 1)
       }}
    end
  end

  # FC computes a line as quantity * unit_price + discount (discount <= 0).
  # Reproduce Xero's tax-exclusive LineAmount exactly: discounts land in
  # `discount`, and non-positive quantities fold into a qty-1 signed price.
  defp line_pricing(line, tax_rate, line_types) do
    qty = decimalize(line["Quantity"] || 1)

    unit =
      case line["UnitAmount"] do
        nil -> nil
        v -> exclusive_unit_price(decimalize(v), tax_rate, line_types)
      end

    la =
      case line["LineAmount"] do
        nil -> implied_line_amount(line, qty, unit)
        v -> exclusive_unit_price(decimalize(v), tax_rate, line_types)
      end

    cond do
      Decimal.compare(qty, 0) != :gt ->
        {Decimal.new(1), la, Decimal.new(0)}

      is_nil(unit) ->
        {qty, safe_div(la, qty), Decimal.new(0)}

      true ->
        discount = Decimal.sub(la, Decimal.mult(qty, unit))

        if Decimal.compare(discount, 0) == :gt do
          {qty, safe_div(la, qty), Decimal.new(0)}
        else
          {qty, unit, discount}
        end
    end
  end

  defp implied_line_amount(line, qty, unit) do
    gross = Decimal.mult(qty, unit || Decimal.new(0))

    cond do
      line["DiscountAmount"] ->
        Decimal.sub(gross, decimalize(line["DiscountAmount"]))

      line["DiscountRate"] ->
        rate = Decimal.div(decimalize(line["DiscountRate"]), Decimal.new(100))
        Decimal.mult(gross, Decimal.sub(Decimal.new(1), rate))

      true ->
        gross
    end
  end

  defp safe_div(num, den) do
    if Decimal.eq?(den, 0), do: num, else: Decimal.div(num, den)
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

  # Xero allows blank numbers on bills; fall back to Reference then the
  # unique InvoiceID (traceable via id_map.json). Gapless ignores both.
  defp invoice_number(inv) do
    presence(inv["InvoiceNumber"]) || presence(inv["Reference"]) ||
      to_string(inv["InvoiceID"] || inv["InvoiceId"])
  end

  @uuid_regex ~r/^[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$/

  defp uuid_like?(val) when is_binary(val), do: Regex.match?(@uuid_regex, val)
  defp uuid_like?(_), do: false

  # Xero UUIDs make unreadable document numbers (payments have no number at
  # all, bank txns/transfers often fall back to their ID). Mint an FC-style
  # sequence instead; Gapless.bump advances the company counters past these
  # after the import, so live numbering continues seamlessly. Readable Xero
  # numbers pass through untouched.
  defp readable_number(candidate, type, ctx) do
    candidate = candidate && to_string(candidate)

    if presence(candidate) && not uuid_like?(candidate) do
      {candidate, ctx}
    else
      seq = Map.get(ctx.number_seq, type, 0) + 1
      ctx = %{ctx | number_seq: Map.put(ctx.number_seq, type, seq)}

      {"#{Gapless.prefix(type)}-#{String.pad_leading(Integer.to_string(seq), 5, "0")}", ctx}
    end
  end

  defp presence(val) when is_binary(val) do
    case String.trim(val) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil

  # Xero supplier bill numbers are not unique; FC enforces uniqueness per
  # company, so collisions get " (2)" suffixes. Payments still land on the
  # right document because invoice_info stores each InvoiceID's final number.
  defp dedupe_doc_number(number, type, ctx, n \\ 1) do
    candidate = if n == 1, do: number, else: "#{number} (#{n})"

    exists? =
      case type do
        :pur_invoice ->
          Repo.exists?(
            from p in FullCircle.Billing.PurInvoice,
              where: p.company_id == ^ctx.company.id and p.pur_invoice_no == ^candidate
          )

        :invoice ->
          Repo.exists?(
            from i in Invoice,
              where: i.company_id == ^ctx.company.id and i.invoice_no == ^candidate
          )
      end

    if exists?, do: dedupe_doc_number(number, type, ctx, n + 1), else: candidate
  end

  defp put_invoice_info(ctx, xero_id, inv, entity, doc_type, number) do
    contact_id = Map.get(entity, :contact_id)

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
      gap = if(kind == :debit_note, do: :DebitNote, else: :CreditNote)

      {number, ctx} =
        readable_number(note["CreditNoteNumber"] || note["CreditNoteID"], gap, ctx)

      attrs = Map.put(attrs, "note_no", number)

      result =
        case kind do
          :debit_note -> DebCre.import_debit_note(attrs, ctx.company, ctx.user)
          :credit_note -> DebCre.import_credit_note(attrs, ctx.company, ctx.user)
        end

      case wrap_import(result) do
        {:ok, _} ->
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

          # Note details have no discount field, so fold it into unit_price.
          {qty, unit_price, discount} =
            line_pricing(line, tax && tax.rate, note["LineAmountTypes"])

          unit_price =
            if Decimal.eq?(discount, 0) do
              unit_price
            else
              Decimal.add(unit_price, safe_div(discount, qty))
            end

          {Integer.to_string(idx),
           %{
             "descriptions" => line["Description"] || note["CreditNoteNumber"] || "Note",
             "account_id" => acc && acc.id,
             "account_name" => acc && acc.name,
             "tax_code_id" => tax && tax.id,
             "tax_code_name" => tax && tax.code,
             "quantity" => qty,
             "unit_price" => unit_price,
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
      Mapper.overpayment_or_prepayment?(pay["Invoice"] || %{}) ->
        persist_overpayment_refund(pay, payment_id, ctx)

      is_nil(invoice_id) or is_nil(info) or not Map.has_key?(ctx.id_map, "invoice:" <> invoice_id) ->
        {:error, {:missing_allocation_target, payment_id, invoice_id || "unknown"}}

      true ->
        apply_allocation(pay, payment_id, info, ctx)
    end
  end

  # A payment against an over/prepayment is a cash refund: the AP side means
  # the supplier returns money (Receipt crediting Account Payables, reversing
  # the SPEND-OVERPAYMENT that debited it); the AR side refunds a customer
  # (Payment debiting Account Receivables).
  defp persist_overpayment_refund(pay, payment_id, ctx) do
    inv = pay["Invoice"] || %{}
    ar? = String.starts_with?(to_string(inv["Type"]), "AR")
    control = if ar?, do: "Account Receivables", else: "Account Payables"

    with {:ok, contact} <- mapped_contact(inv, ctx),
         {:ok, funds} <- payment_funds_account(pay, ctx),
         {:ok, good} <- ensure_named_good(@xero_line_good, ctx),
         {:ok, acc} <- control_account(control, ctx) do
      tax_code = if ar?, do: "NoPTax", else: "NoSTax"
      tax = Accounting.get_tax_code_by_code(tax_code, ctx.company, ctx.user)
      date = parse_date(pay["Date"]) || Date.utc_today()
      amount = decimalize(pay["Amount"] || 0)
      # AR refund pays money out (Payment); AP refund receives it (Receipt).
      {number, ctx} = readable_number(payment_id, if(ar?, do: :Payment, else: :Receipt), ctx)

      detail = %{
        "0" => %{
          "good_id" => good.id,
          "good_name" => good_display_name(good),
          "account_id" => acc.id,
          "account_name" => acc.name,
          "tax_code_id" => tax && tax.id,
          "tax_code_name" => tax && tax.code,
          "package_id" => good.package_id,
          "package_name" => good.package_name || good.unit || "unit",
          # package_qty mirrors quantity — see align_doc_total comment.
          "quantity" => Decimal.new(1),
          "package_qty" => Decimal.new(1),
          "unit_price" => amount,
          "discount" => Decimal.new(0),
          "tax_rate" => Decimal.new(0),
          "unit_multiplier" => "0",
          "descriptions" => "Xero #{inv["Type"]} refund",
          "_persistent_id" => "1"
        }
      }

      if ar? do
        attrs = %{
          "payment_no" => number,
          "payment_date" => date,
          "contact_id" => contact.id,
          "contact_name" => contact.name,
          "funds_account_id" => funds.id,
          "funds_account_name" => funds.name,
          "funds_amount" => amount,
          "payment_details" => detail,
          "transaction_matchers" => %{}
        }

        case wrap_import(BillPay.import_payment(attrs, ctx.company, ctx.user)) do
          {:ok, _} -> {:ok, track_number(ctx, :Payment, number)}
          {:error, _} = err -> err
        end
      else
        attrs = %{
          "receipt_no" => number,
          "receipt_date" => date,
          "contact_id" => contact.id,
          "contact_name" => contact.name,
          "funds_account_id" => funds.id,
          "funds_account_name" => funds.name,
          "funds_amount" => amount,
          "receipt_details" => detail,
          "transaction_matchers" => %{}
        }

        case wrap_import(ReceiveFund.import_receipt(attrs, ctx.company, ctx.user)) do
          {:ok, _} -> {:ok, track_number(ctx, :Receipt, number)}
          {:error, _} = err -> err
        end
      end
    end
  end

  defp control_account(name, ctx) do
    case Accounting.get_account_by_name(name, ctx.company, ctx.user) do
      %{id: _} = acc -> {:ok, acc}
      nil -> {:error, {:unmapped_account, name}}
    end
  end

  defp apply_allocation(pay, payment_id, info, ctx) do
    with {:ok, txn} <- control_transaction(info, ctx),
         {:ok, funds} <- payment_funds_account(pay, ctx) do
      date = parse_date(pay["Date"]) || Date.utc_today()
      amount = decimalize(pay["Amount"] || 0)
      match_amount = signed_match_amount(txn.amount, amount)
      # Xero payments have no document number and References collide en masse
      # (e.g. "Cash" on every POS payment); PaymentIDs are unique but
      # unreadable UUIDs, so mint FC-style numbers (readable ids pass through).
      {number, ctx} =
        readable_number(payment_id, if(info.type == "ACCPAY", do: :Payment, else: :Receipt), ctx)

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
    {number, ctx} =
      readable_number(
        journal["JournalNumber"] || journal["ManualJournalID"] || journal["Narration"],
        :Journal,
        ctx
      )

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
           "particulars" =>
             presence(line["Description"]) || presence(journal["Narration"]) ||
               to_string(number),
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

  @fc_pl_types ["Revenue", "Other Income", "Direct Costs", "Expenses", "Overhead", "Depreciation"]

  # Xero posts payroll and other system journals via the Journals API, which
  # new apps cannot read. Close the gap with one balanced journal per
  # financial year, derived from the yearly TB snapshots: balance-sheet
  # accounts as cumulative diffs, P&L accounts as that-year activity diffs.
  # A period whose documents fully explain its TB posts nothing.
  defp post_catchup_journals(ctx) do
    periods =
      (ctx.snapshot.reports || %{})
      |> report_value("trial_balance_by_year")
      |> List.wrap()
      |> Enum.sort_by(& &1["date"])

    periods
    |> Enum.reduce_while({:ok, {ctx, nil}}, fn period, {:ok, {ctx, prev_date}} ->
      case post_one_catchup(period, prev_date, ctx) do
        {:ok, ctx} -> {:cont, {:ok, {ctx, parse_date(period["date"])}}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, {ctx, _}} -> {:ok, ctx}
      err -> err
    end
  end

  defp report_value(reports, key) when is_map(reports),
    do: Map.get(reports, key) || Map.get(reports, String.to_atom(key))

  defp report_value(_reports, _key), do: nil

  defp post_one_catchup(period, prev_date, ctx) do
    date = parse_date(period["date"])
    xero = catchup_expected(period["lines"] || [], ctx)
    fc_now = fc_balances_at(date, ctx)
    fc_prev = if prev_date, do: fc_balances_at(prev_date, ctx), else: %{}

    names =
      xero |> Map.keys() |> MapSet.new() |> MapSet.union(MapSet.new(Map.keys(fc_now)))

    lines =
      Enum.reduce(names, [], fn name, acc ->
        {type, fc_amt} = Map.get(fc_now, name, {nil, Decimal.new(0)})
        {_, prev_amt} = Map.get(fc_prev, name, {nil, Decimal.new(0)})
        xero_amt = Map.get(xero, name, Decimal.new(0))

        delta =
          if type in @fc_pl_types do
            # Xero TB shows P&L as YTD for that financial year.
            Decimal.sub(xero_amt, Decimal.sub(fc_amt, prev_amt))
          else
            Decimal.sub(xero_amt, fc_amt)
          end

        delta = Decimal.round(delta, 2)
        if Decimal.eq?(delta, 0), do: acc, else: [{name, delta} | acc]
      end)

    with {:ok, lines} <- balance_catchup_lines(lines, ctx) do
      if lines == [] do
        {:ok, ctx}
      else
        persist_catchup_journal(lines, date, ctx)
      end
    end
  end

  defp catchup_expected(rows, ctx) do
    re_name = retained_earnings_name(ctx)

    Enum.reduce(rows, %{}, fn row, acc ->
      name =
        (row["account_name"] || row[:account_name])
        |> Mapper.strip_code_suffix()
        |> Mapper.control_account_name(ctx.overrides)

      cond do
        name in [nil, "", "Total", "Opening Balances", re_name] ->
          acc

        true ->
          amt = decimalize(row["balance"] || row[:balance] || 0)
          Map.update(acc, name, amt, &Decimal.add(&1, amt))
      end
    end)
  end

  defp fc_balances_at(date, ctx) do
    re_name = retained_earnings_name(ctx)

    from(t in Transaction,
      join: a in FullCircle.Accounting.Account,
      on: a.id == t.account_id,
      where: t.company_id == ^ctx.company.id and t.doc_date <= ^date,
      where: a.name != ^re_name,
      group_by: [a.name, a.account_type],
      select: {a.name, a.account_type, sum(t.amount)}
    )
    |> Repo.all()
    |> Map.new(fn {name, type, amt} -> {name, {type, decimalize(amt)}} end)
  end

  # Retained Earnings is excluded from the per-account deltas (Xero's TB RE
  # row is computed, FC's is posted), so any residual IS the RE difference —
  # rounding cents included. Balance the journal against Retained Earnings.
  defp balance_catchup_lines(lines, ctx) do
    residual = Enum.reduce(lines, Decimal.new(0), fn {_n, amt}, acc -> Decimal.add(acc, amt) end)

    if Decimal.eq?(residual, 0) do
      {:ok, lines}
    else
      with {:ok, re} <- retained_earnings_account(ctx) do
        {:ok, [{re.name, Decimal.negate(residual)} | lines]}
      end
    end
  end

  defp persist_catchup_journal(lines, date, ctx) do
    number = "XCATCHUP-#{Date.to_iso8601(date)}"

    transactions =
      lines
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, %{}}, fn {{name, amt}, idx}, {:ok, acc} ->
        case Accounting.get_account_by_name(name, ctx.company, ctx.user) do
          %{id: _} = account ->
            entry = %{
              "account_id" => account.id,
              "account_name" => account.name,
              "particulars" => "Xero catch-up #{Date.to_iso8601(date)}",
              "amount" => amt,
              "_persistent_id" => Integer.to_string(idx)
            }

            {:cont, {:ok, Map.put(acc, Integer.to_string(idx), entry)}}

          nil ->
            {:halt, {:error, {:unmapped_account, name}}}
        end
      end)

    with {:ok, transactions} <- transactions do
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
  end

  # Xero payroll (and other unreadable system journals) post AR/AP per
  # contact; the yearly catch-up journals close the account totals but carry
  # no contact. Post one zero-sum journal that moves the contact-less
  # catch-up onto the contacts Xero's aged balances name.
  defp post_aged_attribution(ctx) do
    lines =
      [{"Account Receivables", "aged_receivables"}, {"Account Payables", "aged_payables"}]
      |> Enum.flat_map(fn {account, report_key} ->
        aged_attribution_lines(account, report_key, ctx)
      end)

    if lines == [] do
      {:ok, ctx}
    else
      date = last_catchup_date(ctx) || Date.utc_today()
      number = "XCATCHUP-AGED"

      transactions =
        lines
        |> Enum.with_index()
        |> Map.new(fn {line, idx} ->
          {Integer.to_string(idx), Map.put(line, "_persistent_id", Integer.to_string(idx))}
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
  end

  defp aged_attribution_lines(account_name, report_key, ctx) do
    account = Accounting.get_account_by_name(account_name, ctx.company, ctx.user)

    expected =
      (ctx.snapshot.reports || %{})
      |> report_value(report_key)
      |> List.wrap()
      |> Enum.reduce(%{}, fn row, acc ->
        name = row["contact_name"] || row[:contact_name]
        amt = decimalize(row["balance"] || row[:balance] || 0)
        if name, do: Map.update(acc, name, amt, &Decimal.add(&1, amt)), else: acc
      end)

    live =
      if account do
        from(t in Transaction,
          join: c in Contact,
          on: c.id == t.contact_id,
          where: t.company_id == ^ctx.company.id and t.account_id == ^account.id,
          group_by: c.name,
          select: {c.name, sum(t.amount)}
        )
        |> Repo.all()
        |> Map.new(fn {name, amt} -> {name, decimalize(amt)} end)
      else
        %{}
      end

    gaps =
      expected
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.union(MapSet.new(Map.keys(live)))
      |> Enum.reduce([], fn name, acc ->
        gap =
          Map.get(expected, name, Decimal.new(0))
          |> Decimal.sub(Map.get(live, name, Decimal.new(0)))
          |> Decimal.round(2)

        if Decimal.eq?(gap, 0), do: acc, else: [{name, gap} | acc]
      end)

    if gaps == [] or is_nil(account) do
      []
    else
      contact_lines =
        gaps
        |> Enum.sort_by(fn {name, _} -> name end)
        |> Enum.flat_map(fn {name, gap} ->
          case Accounting.get_contact_by_name(name, ctx.company, ctx.user) do
            %{id: id} ->
              [
                %{
                  "account_id" => account.id,
                  "account_name" => account.name,
                  "contact_id" => id,
                  "contact_name" => name,
                  "particulars" => "Xero aged attribution",
                  "amount" => gap
                }
              ]

            nil ->
              []
          end
        end)

      offset =
        contact_lines
        |> Enum.reduce(Decimal.new(0), fn line, acc -> Decimal.add(acc, line["amount"]) end)
        |> Decimal.negate()

      if contact_lines == [] or Decimal.eq?(offset, 0) do
        contact_lines
      else
        contact_lines ++
          [
            %{
              "account_id" => account.id,
              "account_name" => account.name,
              "particulars" => "Xero aged attribution offset",
              "amount" => offset
            }
          ]
      end
    end
  end

  defp last_catchup_date(ctx) do
    (ctx.snapshot.reports || %{})
    |> report_value("trial_balance_by_year")
    |> List.wrap()
    |> Enum.map(&parse_date(&1["date"]))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(Date, fn -> nil end)
  end

  # FC's TB/balance-sheet reports show P&L for the current financial year
  # only and expect prior years closed into Retained Earnings (Xero computes
  # retained earnings on the fly, so the history arrives unclosed). Post one
  # XCLOSE-<fye> journal per completed FY moving each P&L account's year
  # result into Retained Earnings. Must run AFTER catch-up journals (their
  # FYE-dated P&L lines belong to the year being closed).
  defp post_closing_journals(ctx) do
    first =
      Repo.one(
        from t in Transaction,
          where: t.company_id == ^ctx.company.id,
          select: min(t.doc_date)
      )

    if is_nil(first) do
      {:ok, ctx}
    else
      today = Date.utc_today()

      first.year..today.year
      |> Enum.map(&fye_date(&1, ctx.company))
      |> Enum.filter(&(Date.compare(&1, today) == :lt))
      |> Enum.reduce_while({:ok, ctx}, fn fye, {:ok, ctx} ->
        case post_one_closing(fye, ctx) do
          {:ok, ctx} -> {:cont, {:ok, ctx}}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  defp fye_date(year, com) do
    month = com.closing_month || 12
    day = min(com.closing_day || 31, Date.days_in_month(Date.new!(year, month, 1)))
    Date.new!(year, month, day)
  end

  # KPST convention: DO NOT reverse individual P&L accounts (that blanks the
  # closed year's P&L report). Post the year's net result through a
  # P&L-typed contra ("Net Profit for The Year", Revenue) against Retained
  # Earnings — prior years then self-cancel in aggregate (TB balances) while
  # every account keeps its history visible.
  defp post_one_closing(fye, ctx) do
    prev = fye_date(fye.year - 1, ctx.company)

    net =
      Repo.one(
        from t in Transaction,
          join: a in FullCircle.Accounting.Account,
          on: a.id == t.account_id,
          where: t.company_id == ^ctx.company.id,
          where: a.account_type in ^FullCircle.Accounting.profit_loss_account_types(),
          where: t.doc_date > ^prev and t.doc_date <= ^fye,
          select: coalesce(sum(t.amount), 0)
      )
      |> decimalize()

    if Decimal.eq?(net, 0) do
      {:ok, ctx}
    else
      with {:ok, re} <- retained_earnings_account(ctx),
           {:ok, npy} <- net_profit_account(ctx) do
        particulars = "Year-end closing #{fye.year}"

        attrs = %{
          "journal_no" => "XCLOSE-#{Date.to_iso8601(fye)}",
          "journal_date" => fye,
          "transactions" => %{
            "0" => %{
              "account_id" => npy.id,
              "account_name" => npy.name,
              "particulars" => particulars,
              "amount" => Decimal.negate(net),
              "_persistent_id" => "0"
            },
            "1" => %{
              "account_id" => re.id,
              "account_name" => re.name,
              "particulars" => particulars,
              "amount" => net,
              "_persistent_id" => "1"
            }
          }
        }

        case wrap_import(JournalEntry.import_journal(attrs, ctx.company, ctx.user)) do
          {:ok, _} -> {:ok, track_number(ctx, :Journal, attrs["journal_no"])}
          {:error, _} = err -> err
        end
      end
    end
  end

  defp net_profit_account(ctx) do
    case Accounting.get_account_by_name("Net Profit for The Year", ctx.company, ctx.user) do
      %{id: _} = acc ->
        {:ok, acc}

      nil ->
        seed_one(
          "Accounts",
          %{"name" => "Net Profit for The Year", "account_type" => "Revenue"},
          ctx
        )
    end
  end

  # The FC-side retained earnings name honors control_accounts overrides
  # (e.g. "Retained Earnings" -> "Retained Profits" to match KPST naming).
  defp retained_earnings_name(ctx) do
    Mapper.control_account_name("Retained Earnings", ctx.overrides)
  end

  defp retained_earnings_account(ctx) do
    name = retained_earnings_name(ctx)

    case Accounting.get_account_by_name(name, ctx.company, ctx.user) do
      %{id: _} = acc ->
        {:ok, acc}

      nil ->
        seed_one("Accounts", %{"name" => name, "account_type" => "Equity"}, ctx)
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
    {txn, flipped?} = maybe_flip_negative_bank_txn(txn)
    spend? = txn["Type"] in @spend_bank_types != flipped?
    receive? = txn["Type"] in @receive_bank_types != flipped?

    cond do
      not bank_txn_importable?(txn) ->
        {:ok, ctx}

      Map.has_key?(txn, "CurrencyCode") and not Mapper.base_currency_ok?(txn, base_currency(ctx)) ->
        {:error, {:foreign_currency, txn["BankTransactionNumber"] || txn["BankTransactionID"]}}

      txn["Type"] not in @spend_bank_types and txn["Type"] not in @receive_bank_types ->
        {:ok, ctx}

      spend? ->
        persist_bank_spend(txn, ctx)

      receive? ->
        persist_bank_receive(txn, ctx)

      true ->
        {:ok, ctx}
    end
  end

  # A negative-total SPEND is money in (a correction entry) and vice versa;
  # FC requires funds_amount > 0, so flip the direction and negate the lines.
  defp maybe_flip_negative_bank_txn(txn) do
    if Decimal.lt?(bank_txn_amount(txn), 0) do
      lines =
        Enum.map(txn["LineItems"] || [], fn line ->
          line
          |> negate_key("UnitAmount")
          |> negate_key("LineAmount")
          |> negate_key("DiscountAmount")
        end)

      txn =
        txn
        |> Map.put("LineItems", lines)
        |> negate_key("Total")
        |> negate_key("TotalAmount")

      {txn, true}
    else
      {txn, false}
    end
  end

  defp negate_key(map, key) do
    case map[key] do
      nil -> map
      val -> Map.put(map, key, Decimal.negate(decimalize(val)))
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

      {number, ctx} =
        readable_number(txn["BankTransactionNumber"] || txn["BankTransactionID"], :Payment, ctx)

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

      {number, ctx} =
        readable_number(txn["BankTransactionNumber"] || txn["BankTransactionID"], :Receipt, ctx)

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
        {number, ctx} = readable_number(xfer["BankTransferID"] || xfer["Reference"], :Journal, ctx)
        date = parse_date(xfer["Date"]) || Date.utc_today()
        amount = decimalize(xfer["Amount"] || 0)
        particulars = presence(xfer["Reference"]) || "Bank transfer"

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

  defp on_or_before?(%Date{} = a, %Date{} = b), do: Date.compare(a, b) != :gt
  defp on_or_before?(_, _), do: false

  defp parse_date(nil), do: nil
  defp parse_date(%Date{} = d), do: d

  # Xero's .NET JSON date: "/Date(1607299200000+0000)/" (ms since epoch, UTC
  # midnight for date-only fields). Payments and manual journals carry ONLY
  # this format — no ISO DateString.
  defp parse_date("/Date(" <> rest) do
    case Integer.parse(rest) do
      {ms, _} -> ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_date()
      :error -> nil
    end
  end

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

  defp exclusive_unit_price(unit_price, tax_rate, "Inclusive") do
    rate = decimalize(tax_rate)

    if Decimal.compare(rate, Decimal.new(0)) == :gt do
      Decimal.div(unit_price, Decimal.add(Decimal.new(1), rate))
    else
      unit_price
    end
  end

  defp exclusive_unit_price(unit_price, _tax_rate, _line_types), do: unit_price

  defp decimalize(nil), do: Decimal.new(0)
  defp decimalize(%Decimal{} = d), do: d
  defp decimalize(n) when is_integer(n), do: Decimal.new(n)
  defp decimalize(n) when is_float(n), do: n |> to_string() |> Decimal.new()
  defp decimalize(bin) when is_binary(bin), do: Decimal.new(bin)
  defp decimalize(_), do: Decimal.new(0)
end
