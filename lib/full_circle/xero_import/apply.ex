defmodule FullCircle.XeroImport.Apply do
  import Ecto.Query, warn: false

  alias FullCircle.{Accounting, Product, Repo, Seeding, Sys}
  alias FullCircle.Accounting.{Contact, Transaction}
  alias FullCircle.Billing.Invoice
  alias FullCircle.Sys.{Company, CompanyUser}
  alias FullCircle.XeroImport.Mapper

  @default_company_name "Golden Husbandry Sdn. Bhd."

  @default_control_accounts %{
    "Accounts Receivable" => "Account Receivables",
    "Accounts Payable" => "Account Payables",
    "GST" => "Sales Tax Payable"
  }

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
           tax_by_type: %{}
         },
         {:ok, ctx} <- import_accounts(ctx),
         {:ok, ctx} <- import_tax_codes(ctx),
         {:ok, ctx} <- import_contacts(ctx),
         {:ok, ctx} <- import_goods(ctx),
         {:ok, ctx} <- import_fixed_assets(ctx) do
      {:ok, %{company: ctx.company, id_map: ctx.id_map}}
    end
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

    case Product.get_good_by_name(attrs["name"], ctx.company, ctx.user) do
      %{id: id} ->
        {:ok, put_id(ctx, "good:" <> to_string(xero_id), id)}

      nil ->
        case seed_one("Goods", attrs, ctx) do
          {:ok, good} -> {:ok, put_id(ctx, "good:" <> to_string(xero_id), good.id)}
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
end
