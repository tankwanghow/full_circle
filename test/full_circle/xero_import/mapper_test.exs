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

  describe "expand_depreciation_history/3" do
    @com %{closing_month: 12, closing_day: 31}

    defp fa_map(over \\ %{}) do
      Map.merge(
        %{
          depre_rate: Decimal.new("0.1"),
          depre_interval: "Monthly",
          depre_start_date: ~D[2021-01-18],
          pur_date: ~D[2021-01-18],
          pur_price: Decimal.new("7350")
        },
        over
      )
    end

    defp lump(amount, date \\ "2021-01-18", cost \\ 7350.0) do
      [%{"DepreciationDate" => date, "DepreciationAmount" => amount, "CostLimit" => cost}]
    end

    defp sum_amounts(rows) do
      Enum.reduce(rows, Decimal.new("0"), &Decimal.add(&2, &1["DepreciationAmount"]))
    end

    test "expands the GH lump into monthly closing-day rows summing exactly" do
      rows = Mapper.expand_depreciation_history(lump(2940.0), fa_map(), @com)

      assert length(rows) == 48
      assert List.first(rows)["DepreciationDate"] == "2021-01-31"
      assert List.last(rows)["DepreciationDate"] == "2024-12-31"
      assert Enum.all?(rows, &Decimal.eq?(&1["DepreciationAmount"], Decimal.new("61.25")))
      assert Decimal.eq?(sum_amounts(rows), Decimal.new("2940.00"))
    end

    test "last row absorbs the remainder so the sum stays exact" do
      rows = Mapper.expand_depreciation_history(lump(2906.41), fa_map(), @com)

      assert length(rows) == 47
      assert Enum.take(rows, 46) |> Enum.all?(&Decimal.eq?(&1["DepreciationAmount"], "61.25"))
      assert Decimal.eq?(List.last(rows)["DepreciationAmount"], Decimal.new("88.91"))
      assert Decimal.eq?(sum_amounts(rows), Decimal.new("2906.41"))
    end

    test "yearly interval expands on closing month/day" do
      fa =
        fa_map(%{
          depre_rate: Decimal.new("0.2"),
          depre_interval: "Yearly",
          depre_start_date: ~D[2023-01-01],
          pur_date: ~D[2023-01-01],
          pur_price: Decimal.new("100000")
        })

      rows =
        Mapper.expand_depreciation_history(lump(40_000.0, "2023-01-01", 100_000.0), fa, @com)

      assert Enum.map(rows, & &1["DepreciationDate"]) == ["2023-12-31", "2024-12-31"]
      assert Enum.all?(rows, &Decimal.eq?(&1["DepreciationAmount"], Decimal.new("20000")))
    end

    test "first date is clamped up to the depreciation start date" do
      fa = fa_map(%{depre_start_date: ~D[2021-01-28], pur_date: ~D[2021-01-28]})
      com = %{closing_month: 12, closing_day: 25}

      rows = Mapper.expand_depreciation_history(lump(122.5, "2021-01-28"), fa, com)

      assert Enum.map(rows, & &1["DepreciationDate"]) == ["2021-01-28", "2021-02-25"]
    end

    test "February anchor falls back to end of month" do
      fa = fa_map(%{depre_start_date: ~D[2021-02-10], pur_date: ~D[2021-02-10]})

      rows = Mapper.expand_depreciation_history(lump(122.5, "2021-02-10"), fa, @com)

      assert Enum.map(rows, & &1["DepreciationDate"]) == ["2021-02-28", "2021-03-31"]
    end

    test "passes through histories that are not a synthesized lump" do
      # multi-row history
      two = lump(61.25) ++ [%{"DepreciationDate" => "2021-02-28", "DepreciationAmount" => 61.25}]
      assert Mapper.expand_depreciation_history(two, fa_map(), @com) == two

      # single row dated neither at start nor purchase date
      hand = lump(2940.0, "2024-06-30")
      assert Mapper.expand_depreciation_history(hand, fa_map(), @com) == hand

      # zero rate
      zero_rate = fa_map(%{depre_rate: Decimal.new("0")})
      assert Mapper.expand_depreciation_history(lump(2940.0), zero_rate, @com) == lump(2940.0)

      # lump within a single period
      assert Mapper.expand_depreciation_history(lump(61.25), fa_map(), @com) == lump(61.25)

      # empty history
      assert Mapper.expand_depreciation_history([], fa_map(), @com) == []
    end
  end
end
