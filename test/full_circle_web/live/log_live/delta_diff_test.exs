defmodule FullCircleWeb.LogLive.DeltaDiffTest do
  use ExUnit.Case, async: true

  alias FullCircleWeb.LogLive.DeltaDiff

  describe "parse/1" do
    test "nil returns empty map" do
      assert DeltaDiff.parse(nil) == %{}
    end

    test "empty string returns empty map" do
      assert DeltaDiff.parse("") == %{}
    end

    test "unformatted legacy delta returns raw_content" do
      assert DeltaDiff.parse("some plain text") == %{"raw_content" => "some plain text"}
    end

    test "single flat field" do
      assert DeltaDiff.parse("&^name: Alice^&") == %{"name" => "Alice"}
    end

    test "multiple flat fields" do
      delta = "&^name: Alice^& &^age: 30^&"
      result = DeltaDiff.parse(delta)
      assert result == %{"name" => "Alice", "age" => "30"}
    end

    test "value with colon is preserved" do
      delta = "&^time: 10:30:00^&"
      assert DeltaDiff.parse(delta) == %{"time" => "10:30:00"}
    end

    test "HTML-escaped value is preserved as-is" do
      delta = "&^note: a &amp; b^&"
      result = DeltaDiff.parse(delta)
      assert result["note"] == "a &amp; b"
    end

    test "nested single level" do
      delta = "&^details: [&^qty: 5^& &^price: 10^&]^&"
      result = DeltaDiff.parse(delta)
      assert result == %{"details" => %{"qty" => "5", "price" => "10"}}
    end

    test "nested with numeric indexes (cast_assoc pattern)" do
      delta = "&^details: [&^0: [&^qty: 5^&]^& &^1: [&^qty: 10^&]^&]^&"
      result = DeltaDiff.parse(delta)

      assert result == %{
               "details" => %{
                 "0" => %{"qty" => "5"},
                 "1" => %{"qty" => "10"}
               }
             }
    end

    test "mixed flat and nested fields" do
      delta = "&^invoice_no: INV-001^& &^details: [&^0: [&^qty: 5^&]^&]^&"
      result = DeltaDiff.parse(delta)

      assert result == %{
               "invoice_no" => "INV-001",
               "details" => %{
                 "0" => %{"qty" => "5"}
               }
             }
    end

    test "three levels of nesting" do
      delta = "&^a: [&^b: [&^c: deep^&]^&]^&"
      result = DeltaDiff.parse(delta)
      assert result == %{"a" => %{"b" => %{"c" => "deep"}}}
    end

    test "empty nested block" do
      delta = "&^details: []^&"
      result = DeltaDiff.parse(delta)
      assert result == %{"details" => %{}}
    end
  end

  describe "diff/2" do
    test "two identical flat maps" do
      map = %{"name" => "Alice", "age" => "30"}
      entries = DeltaDiff.diff(map, map)

      assert Enum.all?(entries, fn e -> e.status == :unchanged end)
      assert length(entries) == 2
    end

    test "field changed" do
      old = %{"amount" => "510.00"}
      new = %{"amount" => "600.00"}
      [entry] = DeltaDiff.diff(old, new)

      assert entry.key == "amount"
      assert entry.status == :changed
      assert entry.old_value == "510.00"
      assert entry.new_value == "600.00"
    end

    test "field added" do
      old = %{"name" => "Alice"}
      new = %{"name" => "Alice", "email" => "a@b.com"}
      entries = DeltaDiff.diff(old, new)

      added = Enum.find(entries, &(&1.key == "email"))
      assert added.status == :added
      assert added.value == "a@b.com"
    end

    test "field removed" do
      old = %{"name" => "Alice", "email" => "a@b.com"}
      new = %{"name" => "Alice"}
      entries = DeltaDiff.diff(old, new)

      removed = Enum.find(entries, &(&1.key == "email"))
      assert removed.status == :removed
      assert removed.value == "a@b.com"
    end

    test "nested maps produce :nested status with children" do
      old = %{"details" => %{"qty" => "5", "price" => "10"}}
      new = %{"details" => %{"qty" => "5", "price" => "20"}}
      [entry] = DeltaDiff.diff(old, new)

      assert entry.key == "details"
      assert entry.status == :nested
      assert is_list(entry.children)

      price_entry = Enum.find(entry.children, &(&1.key == "price"))
      assert price_entry.status == :changed
      assert price_entry.old_value == "10"
      assert price_entry.new_value == "20"
    end

    test "added nested map" do
      old = %{}
      new = %{"details" => %{"qty" => "5"}}
      [entry] = DeltaDiff.diff(old, new)

      assert entry.key == "details"
      assert entry.status == :added_nested
      assert entry.value == %{"qty" => "5"}
    end

    test "removed nested map" do
      old = %{"details" => %{"qty" => "5"}}
      new = %{}
      [entry] = DeltaDiff.diff(old, new)

      assert entry.key == "details"
      assert entry.status == :removed_nested
      assert entry.value == %{"qty" => "5"}
    end

    test "numeric keys are sorted numerically" do
      old = %{"2" => "c", "0" => "a", "10" => "d", "1" => "b"}
      new = %{"2" => "c", "0" => "a", "10" => "d", "1" => "b"}
      entries = DeltaDiff.diff(old, new)
      keys = Enum.map(entries, & &1.key)

      assert keys == ["0", "1", "2", "10"]
    end

    test "mixed numeric and alpha keys sort correctly" do
      old = %{"1" => "a", "name" => "x", "0" => "b"}
      new = old
      entries = DeltaDiff.diff(old, new)
      keys = Enum.map(entries, & &1.key)

      assert keys == ["0", "1", "name"]
    end

    test "both maps empty" do
      assert DeltaDiff.diff(%{}, %{}) == []
    end

    test "complex multi-level diff" do
      old = %{
        "invoice_no" => "INV-001",
        "details" => %{
          "0" => %{"qty" => "5", "price" => "10"},
          "1" => %{"qty" => "3", "price" => "20"}
        }
      }

      new = %{
        "invoice_no" => "INV-001",
        "details" => %{
          "0" => %{"qty" => "5", "price" => "15"},
          "1" => %{"qty" => "3", "price" => "20"}
        }
      }

      entries = DeltaDiff.diff(old, new)
      inv_entry = Enum.find(entries, &(&1.key == "invoice_no"))
      assert inv_entry.status == :unchanged

      details_entry = Enum.find(entries, &(&1.key == "details"))
      assert details_entry.status == :nested

      child_0 = Enum.find(details_entry.children, &(&1.key == "0"))
      assert child_0.status == :nested

      price_change = Enum.find(child_0.children, &(&1.key == "price"))
      assert price_change.status == :changed
      assert price_change.old_value == "10"
      assert price_change.new_value == "15"
    end
  end

  describe "flatten_map/1" do
    test "flat map" do
      result = DeltaDiff.flatten_map(%{"a" => "1", "b" => "2"})
      assert result == [{"a", "1"}, {"b", "2"}]
    end

    test "nested map with prefix" do
      result = DeltaDiff.flatten_map(%{"0" => %{"qty" => "5", "price" => "10"}})
      assert result == [{"0.price", "10"}, {"0.qty", "5"}]
    end
  end
end
