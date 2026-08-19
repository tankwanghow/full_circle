defmodule FullCircle.XeroImport.Mapper do
  @control_accounts %{
    "Accounts Receivable" => "Account Receivables",
    "Accounts Payable" => "Account Payables",
    "GST" => "Sales Tax Payable"
  }

  @overpayment_types ~w(AROVERPAYMENT APOVERPAYMENT ARPREPAYMENT APPREPAYMENT)

  @account_types %{
    "BANK" => "Bank",
    "CURRENT" => "Current Asset",
    "FIXED" => "Fixed Asset",
    "INVENTORY" => "Inventory",
    "PREPAYMENT" => "Prepayment",
    "NONCURRENT" => "Non-current Asset",
    "CURRLIAB" => "Current Liability",
    "LIABILITY" => "Liability",
    "TERMLIAB" => "Non-current Liability",
    "EQUITY" => "Equity",
    "REVENUE" => "Revenue",
    "SALES" => "Revenue",
    "OTHERINCOME" => "Other Income",
    "DIRECTCOSTS" => "Direct Costs",
    "EXPENSE" => "Expenses",
    "OVERHEADS" => "Overhead",
    "DEPRECIATN" => "Depreciation"
  }

  @importable_statuses ~w(AUTHORISED PAID)

  def control_account_name(name, overrides \\ %{})

  def control_account_name(name, overrides) when is_binary(name) do
    custom = get_in(overrides || %{}, ["control_accounts", name])
    custom || Map.get(@control_accounts, name) || name
  end

  def control_account_name(name, _overrides), do: name

  def overpayment_or_prepayment?(doc) when is_map(doc) do
    Map.get(doc, "Type") in @overpayment_types
  end

  def account_type(xero_type, overrides) when is_binary(xero_type) and is_map(overrides) do
    override =
      overrides
      |> Map.get("account_types", %{})
      |> Map.get(xero_type)

    cond do
      is_binary(override) ->
        {:ok, override}

      Map.has_key?(@account_types, xero_type) ->
        {:ok, @account_types[xero_type]}

      true ->
        {:error, {:unmapped_account_type, xero_type}}
    end
  end

  def tax_codes(%{"Name" => name} = rate) do
    slug = tax_slug(name)
    frac = rate_fraction(Map.get(rate, "EffectiveRate", 0))
    sales? = Map.get(rate, "CanApplyToRevenue", false) == true
    purchase? = Map.get(rate, "CanApplyToExpenses", false) == true
    dual? = sales? and purchase?

    []
    |> maybe_tax(sales?, slug, dual?, "-S", "Sales", name, frac)
    |> maybe_tax(purchase?, slug, dual?, "-P", "Purchase", name, frac)
  end

  def contact(xero_contact) when is_map(xero_contact) do
    addr = primary_address(Map.get(xero_contact, "Addresses", []))

    %{
      "name" => Map.get(xero_contact, "Name"),
      "category" => contact_category(xero_contact),
      "country" => blank_to_malaysia(Map.get(addr, "Country") || Map.get(xero_contact, "Country")),
      "address1" => Map.get(addr, "AddressLine1"),
      "address2" => Map.get(addr, "AddressLine2"),
      "city" => Map.get(addr, "City"),
      "state" => Map.get(addr, "Region"),
      "zipcode" => Map.get(addr, "PostalCode"),
      "email" => Map.get(xero_contact, "EmailAddress"),
      "phone" => contact_phone(xero_contact),
      "tax_id" => Map.get(xero_contact, "TaxNumber"),
      "reg_no" => Map.get(xero_contact, "CompanyNumber")
    }
    |> reject_nils()
  end

  def good(xero_item, accounts_by_code, tax_by_type)
      when is_map(xero_item) and is_map(accounts_by_code) and is_map(tax_by_type) do
    sales = Map.get(xero_item, "SalesDetails") || %{}
    purchase = Map.get(xero_item, "PurchaseDetails") || %{}

    %{
      "name" => Map.get(xero_item, "Name") || Map.get(xero_item, "Code"),
      "unit" => Map.get(xero_item, "Unit") || Map.get(xero_item, "QuantityUnit") || "unit",
      "descriptions" => Map.get(xero_item, "Description"),
      "sales_account_name" => account_name(accounts_by_code, Map.get(sales, "AccountCode")),
      "purchase_account_name" => account_name(accounts_by_code, Map.get(purchase, "AccountCode")),
      "sales_tax_code_name" => tax_code_name(tax_by_type, Map.get(sales, "TaxType"), "Sales"),
      "purchase_tax_code_name" =>
        tax_code_name(tax_by_type, Map.get(purchase, "TaxType"), "Purchase")
    }
    |> reject_nils()
  end

  def fixed_asset(xero_asset) when is_map(xero_asset) do
    method = Map.get(xero_asset, "DepreciationMethod")
    name = Map.get(xero_asset, "AssetName") || "unknown"

    case method do
      other when other in ["StraightLine", "NoDepreciation", "FullDepreciationAtPurchase"] ->
        {:ok, fixed_asset_attrs(xero_asset, other)}

      _ ->
        {:error, {:diminishing_value, name}}
    end
  end

  def importable_invoice?(doc) when is_map(doc) do
    Map.get(doc, "Status") in @importable_statuses
  end

  def base_currency_ok?(doc, base) when is_map(doc) and is_binary(base) do
    Map.get(doc, "CurrencyCode") == base
  end

  defp fixed_asset_attrs(asset, method) do
    {depre_method, depre_rate} =
      case method do
        "StraightLine" ->
          {"Straight-Line", rate_fraction(Map.get(asset, "DepreciationRate", 0))}

        _ ->
          {"No Depreciation", Decimal.new("0")}
      end

    %{
      "name" => Map.get(asset, "AssetName"),
      "pur_date" => parse_date(Map.get(asset, "PurchaseDate")),
      "pur_price" => decimalize(Map.get(asset, "PurchasePrice")),
      "residual_value" => decimalize(Map.get(asset, "ResidualValue") || 0),
      "depre_start_date" => parse_date(Map.get(asset, "DepreciationStartDate")),
      "depre_method" => depre_method,
      "depre_rate" => depre_rate,
      "depre_interval" => depre_interval(Map.get(asset, "AveragingMethod")),
      "status" => "Active"
    }
    |> reject_nils()
  end

  defp depre_interval(nil), do: "Yearly"
  defp depre_interval(""), do: "Yearly"

  defp depre_interval(method) when is_binary(method) do
    down = String.downcase(method)

    cond do
      down in ["actualdays", "monthly", "fullday"] -> "Monthly"
      String.contains?(down, "month") -> "Monthly"
      down in ["yearly", "annual", "actualdaysyearly"] -> "Yearly"
      String.contains?(down, "year") or String.contains?(down, "annual") -> "Yearly"
      true -> "Yearly"
    end
  end

  defp depre_interval(_), do: "Yearly"

  defp tax_slug(name) when is_binary(name) do
    name
    |> String.replace(~r/[^A-Za-z0-9]/, "")
    |> String.slice(0, 12)
  end

  defp maybe_tax(acc, false, _slug, _dual?, _suffix, _tax_type, _name, _rate), do: acc

  defp maybe_tax(acc, true, slug, dual?, suffix, tax_type, name, rate) do
    code = if dual?, do: slug <> suffix, else: slug

    [
      %{code: code, tax_type: tax_type, rate: rate, descriptions: name}
      | acc
    ]
  end

  defp rate_fraction(nil), do: Decimal.new("0")

  defp rate_fraction(%Decimal{} = d) do
    Decimal.div(d, Decimal.new("100"))
  end

  defp rate_fraction(n) when is_number(n) do
    n
    |> to_string()
    |> Decimal.new()
    |> Decimal.div(Decimal.new("100"))
  end

  defp rate_fraction(bin) when is_binary(bin) do
    bin |> Decimal.new() |> Decimal.div(Decimal.new("100"))
  end

  defp decimalize(nil), do: nil
  defp decimalize(%Decimal{} = d), do: d
  defp decimalize(n) when is_number(n), do: n |> to_string() |> Decimal.new()
  defp decimalize(bin) when is_binary(bin), do: Decimal.new(bin)

  defp parse_date(nil), do: nil
  defp parse_date(%Date{} = d), do: d

  defp parse_date(<<y::binary-size(4), "-", m::binary-size(2), "-", d::binary-size(2), _::binary>>) do
    Date.from_iso8601!("#{y}-#{m}-#{d}")
  end

  defp parse_date(<<y::binary-size(4), "-", m::binary-size(2), "-", d::binary-size(2)>>) do
    Date.from_iso8601!("#{y}-#{m}-#{d}")
  end

  defp parse_date(other) when is_binary(other) do
    case Date.from_iso8601(other) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp contact_category(c) do
    customer? = Map.get(c, "IsCustomer") == true
    supplier? = Map.get(c, "IsSupplier") == true

    cond do
      customer? and supplier? -> "Customer, Supplier"
      customer? -> "Customer"
      supplier? -> "Supplier"
      true -> nil
    end
  end

  defp blank_to_malaysia(nil), do: "Malaysia"
  defp blank_to_malaysia(""), do: "Malaysia"
  defp blank_to_malaysia(country) when is_binary(country), do: country
  defp blank_to_malaysia(_), do: "Malaysia"

  defp primary_address(addresses) when is_list(addresses) do
    Enum.find(addresses, %{}, fn a ->
      Map.get(a, "AddressType") in ["STREET", "POBOX", nil] or map_size(a) > 0
    end)
    |> case do
      nil -> %{}
      addr -> addr
    end
  end

  defp primary_address(_), do: %{}

  defp contact_phone(c) do
    phones = Map.get(c, "Phones") || []

    case Enum.find(phones, &(Map.get(&1, "PhoneNumber") not in [nil, ""])) do
      %{"PhoneNumber" => n} = p ->
        [Map.get(p, "PhoneCountryCode"), Map.get(p, "PhoneAreaCode"), n]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join(" ")
        |> String.trim()
        |> then(fn
          "" -> nil
          s -> s
        end)

      _ ->
        Map.get(c, "Phone")
    end
  end

  defp account_name(_by_code, nil), do: nil

  defp account_name(by_code, code) do
    case Map.get(by_code, code) do
      nil -> nil
      name when is_binary(name) -> name
      %{"Name" => name} -> name
      %{name: name} when is_binary(name) -> name
      other -> other
    end
  end

  defp tax_code_name(_by_type, nil, _side), do: nil

  defp tax_code_name(by_type, xero_tax_type, side) do
    case Map.get(by_type, xero_tax_type) do
      nil ->
        nil

      code when is_binary(code) ->
        code

      %{} = m ->
        Map.get(m, side) || Map.get(m, :code) || Map.get(m, "code")

      list when is_list(list) ->
        list
        |> Enum.find(fn
          %{tax_type: ^side} -> true
          %{"tax_type" => ^side} -> true
          _ -> false
        end)
        |> case do
          %{code: c} -> c
          %{"code" => c} -> c
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp reject_nils(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
