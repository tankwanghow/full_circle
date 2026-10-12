defmodule FullCircle.FileSpecBankTest do
  use ExUnit.Case, async: true

  alias FullCircle.FileSpec

  defp delimited(sections, extra \\ %{}) do
    Map.merge(%{"renderer" => "text", "delimiter" => ",", "sections" => sections}, extra)
  end

  describe "allowed sources" do
    test "validate/3 accepts a caller-allowed source" do
      spec =
        delimited([
          %{"kind" => "detail", "source" => "payments", "fields" => [%{"expr" => "name"}]}
        ])

      assert :ok = FileSpec.validate(spec, ["name"], ["payments"])
    end

    test "validate/2 still only allows statutory_rows" do
      spec =
        delimited([
          %{"kind" => "detail", "source" => "payments", "fields" => [%{"expr" => "name"}]}
        ])

      assert {:error, [msg]} = FileSpec.validate(spec, ["name"])
      assert msg =~ "statutory_rows"
    end
  end

  describe "computed" do
    test "computed columns render per row and sum in the footer" do
      spec =
        delimited(
          [
            %{
              "kind" => "detail",
              "source" => "payments",
              "fields" => [%{"expr" => "name"}, %{"expr" => "double", "format" => "decimal:0"}]
            },
            %{
              "kind" => "footer",
              "fields" => [%{"expr" => ~s|sum("double")|, "format" => "decimal:0"}]
            }
          ],
          %{"computed" => %{"double" => "amount * 2"}, "line_ending" => "\n"}
        )

      rows = [%{"name" => "a", "amount" => 1.5}, %{"name" => "b", "amount" => 2}]

      assert {:ok, "a,3\nb,4\n7\n"} =
               FileSpec.render(spec, rows, %{}, ["name", "amount"], ["payments"])
    end

    test "computed expressions are validated" do
      spec =
        delimited(
          [%{"kind" => "detail", "source" => "payments", "fields" => [%{"expr" => "x"}]}],
          %{"computed" => %{"x" => "nope + 1"}}
        )

      assert {:error, [msg]} = FileSpec.validate(spec, [], ["payments"])
      assert msg =~ "computed x: unknown identifier 'nope'"
    end

    test "computed must be a map" do
      spec =
        delimited([%{"kind" => "header", "fields" => [%{"expr" => "1"}]}], %{"computed" => ["x"]})

      assert {:error, [msg]} = FileSpec.validate(spec, [], ["payments"])
      assert msg =~ "computed must be a map"
    end

    test "a computed evaluation error is returned, not raised" do
      spec =
        delimited(
          [%{"kind" => "detail", "source" => "payments", "fields" => [%{"expr" => "x"}]}],
          %{"computed" => %{"x" => "left(d, 4)"}}
        )

      assert {:error, msg} =
               FileSpec.render(spec, [%{"d" => ~D[2026-01-01]}], %{}, ["d"], ["payments"])

      assert msg =~ "computed x"
    end
  end
end
