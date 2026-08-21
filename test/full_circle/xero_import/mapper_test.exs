defmodule FullCircle.XeroImport.MapperTest do
  use ExUnit.Case, async: true
  alias FullCircle.XeroImport.Mapper

  test "control account names map onto Full Circle defaults" do
    assert Mapper.control_account_name("Accounts Receivable") == "Account Receivables"
    assert Mapper.control_account_name("Accounts Payable") == "Account Payables"
    assert Mapper.control_account_name("GST") == "Sales Tax Payable"
    assert Mapper.control_account_name("Sales") == "Sales"
  end

  test "contact prefers the STREET address over other address types" do
    contact = %{
      "Name" => "Alice",
      "Addresses" => [
        %{"AddressType" => "DELIVERY", "City" => "Delivery Town", "AddressLine1" => "Dock 9"},
        %{"AddressType" => "STREET", "City" => "Street Town", "AddressLine1" => "1 Main St"}
      ]
    }

    attrs = Mapper.contact(contact)
    assert attrs["city"] == "Street Town"
    assert attrs["address1"] == "1 Main St"
  end

  test "overpayment invoice types are detected" do
    assert Mapper.overpayment_or_prepayment?(%{"Type" => "AROVERPAYMENT"})
    assert Mapper.overpayment_or_prepayment?(%{"Type" => "ARPREPAYMENT"})
    refute Mapper.overpayment_or_prepayment?(%{"Type" => "ACCREC"})
  end

  test "maps every specified Xero account type" do
    assert Mapper.account_type("BANK", %{}) == {:ok, "Bank"}
    assert Mapper.account_type("REVENUE", %{}) == {:ok, "Revenue"}
    assert Mapper.account_type("SALES", %{}) == {:ok, "Revenue"}
    assert Mapper.account_type("DEPRECIATN", %{}) == {:ok, "Depreciation"}
  end

  test "unknown type without override fails" do
    assert {:error, {:unmapped_account_type, "WEIRD"}} = Mapper.account_type("WEIRD", %{})
  end

  test "override wins" do
    assert Mapper.account_type("WEIRD", %{"account_types" => %{"WEIRD" => "Expenses"}}) ==
             {:ok, "Expenses"}
  end

  test "6% dual-apply tax becomes two codes at 0.06" do
    codes =
      Mapper.tax_codes(%{
        "Name" => "SST 6%",
        "EffectiveRate" => 6.0,
        "CanApplyToRevenue" => true,
        "CanApplyToExpenses" => true
      })

    assert Enum.map(codes, & &1.tax_type) |> Enum.sort() == ["Purchase", "Sales"]
    assert Enum.all?(codes, &Decimal.eq?(&1.rate, Decimal.new("0.06")))
    assert Enum.any?(codes, &String.ends_with?(&1.code, "-S"))
    assert Enum.any?(codes, &String.ends_with?(&1.code, "-P"))
  end

  test "blank contact country becomes Malaysia" do
    c = Mapper.contact(%{"Name" => "Alice", "IsCustomer" => true, "Addresses" => []})
    assert c["country"] == "Malaysia"
    assert c["category"] == "Customer"
  end

  test "diminishing-value asset fails" do
    assert {:error, {:diminishing_value, _}} =
             Mapper.fixed_asset(%{
               "AssetName" => "Van",
               "DepreciationMethod" => "DiminishingValue"
             })
  end

  test "straight-line asset rate is a fraction" do
    {:ok, fa} =
      Mapper.fixed_asset(%{
        "AssetName" => "Van 1",
        "PurchaseDate" => "2023-01-01",
        "PurchasePrice" => 100_000.0,
        "ResidualValue" => 10000.0,
        "DepreciationStartDate" => "2023-01-01",
        "DepreciationMethod" => "StraightLine",
        "DepreciationRate" => 20.0,
        "AveragingMethod" => "Monthly"
      })

    assert fa["depre_method"] == "Straight-Line"
    assert Decimal.eq?(fa["depre_rate"], Decimal.new("0.2"))
    assert fa["depre_interval"] == "Monthly"
  end

  test "straight-line asset without rate derives it from effective life years" do
    {:ok, fa} =
      Mapper.fixed_asset(%{
        "AssetName" => "Freezer",
        "PurchaseDate" => "2021-01-01",
        "PurchasePrice" => 1690.0,
        "ResidualValue" => 0,
        "DepreciationStartDate" => "2021-01-01",
        "DepreciationMethod" => "StraightLine",
        "DepreciationRate" => nil,
        "EffectiveLifeYears" => 10,
        "AveragingMethod" => "FullMonth"
      })

    assert Decimal.eq?(fa["depre_rate"], Decimal.new("0.1"))
  end

  test "straight-line asset with neither rate nor life keeps rate 0" do
    {:ok, fa} =
      Mapper.fixed_asset(%{
        "AssetName" => "Mystery",
        "PurchaseDate" => "2021-01-01",
        "PurchasePrice" => 100.0,
        "DepreciationStartDate" => "2021-01-01",
        "DepreciationMethod" => "StraightLine"
      })

    assert Decimal.eq?(fa["depre_rate"], Decimal.new("0"))
  end

  test "skips draft and void invoices" do
    refute Mapper.importable_invoice?(%{"Status" => "DRAFT", "Type" => "ACCREC"})
    refute Mapper.importable_invoice?(%{"Status" => "VOIDED", "Type" => "ACCREC"})
    assert Mapper.importable_invoice?(%{"Status" => "AUTHORISED", "Type" => "ACCREC"})
    assert Mapper.importable_invoice?(%{"Status" => "PAID", "Type" => "ACCREC"})
  end

  test "rejects non-base currency" do
    refute Mapper.base_currency_ok?(%{"CurrencyCode" => "USD"}, "MYR")
    assert Mapper.base_currency_ok?(%{"CurrencyCode" => "MYR"}, "MYR")
  end
end
