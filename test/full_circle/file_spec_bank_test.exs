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

  describe "children" do
    test "child lines follow their parent and see parent + prefixed item keys" do
      spec =
        delimited(
          [
            %{
              "kind" => "detail",
              "source" => "payments",
              "fields" => [%{"expr" => ~s|"10"|}, %{"expr" => "no"}],
              "children" => [
                %{
                  "source" => "advice",
                  "fields" => [
                    %{"expr" => ~s|"30"|},
                    %{"expr" => "no"},
                    %{"expr" => "advice_doc_no"},
                    %{"expr" => "advice_amount", "format" => "decimal:2"}
                  ]
                }
              ]
            },
            %{"kind" => "footer", "fields" => [%{"expr" => "count()", "format" => "decimal:0"}]}
          ],
          %{"line_ending" => "\n"}
        )

      rows = [
        %{
          "no" => "P1",
          "advice" => [
            %{"doc_no" => "I1", "amount" => Decimal.new("5")},
            %{"doc_no" => "I2", "amount" => Decimal.new("6.5")}
          ]
        },
        %{"no" => "P2", "advice" => []}
      ]

      vars = ["no", "advice", "advice_doc_no", "advice_amount"]

      assert {:ok, "10,P1\n30,P1,I1,5.00\n30,P1,I2,6.50\n10,P2\n2\n"} =
               FileSpec.render(spec, rows, %{}, vars, ["payments"])
    end

    test "a child needs a source" do
      spec =
        delimited([
          %{
            "kind" => "detail",
            "source" => "payments",
            "fields" => [%{"expr" => "no"}],
            "children" => [%{"fields" => [%{"expr" => "no"}]}]
          }
        ])

      assert {:error, [msg]} = FileSpec.validate(spec, ["no"], ["payments"])
      assert msg =~ "child 1: source is required"
    end
  end

  describe "quote csv" do
    test "wraps values holding the delimiter or quotes, doubling inner quotes" do
      spec =
        delimited(
          [
            %{
              "kind" => "detail",
              "source" => "payments",
              "fields" => [%{"expr" => "name"}, %{"expr" => "note"}]
            }
          ],
          %{"quote" => "csv", "line_ending" => "\n"}
        )

      rows = [
        %{"name" => "Tan, Lee", "note" => ~s|say "hi"|},
        %{"name" => "Plain", "note" => "x"}
      ]

      assert {:ok, ~s|"Tan, Lee","say ""hi"""\nPlain,x\n|} =
               FileSpec.render(spec, rows, %{}, ["name", "note"], ["payments"])
    end

    test "quote needs a delimiter" do
      spec = %{
        "renderer" => "text",
        "quote" => "csv",
        "sections" => [%{"kind" => "header", "fields" => [%{"expr" => "1", "width" => 1}]}]
      }

      assert {:error, [msg]} = FileSpec.validate(spec, [], ["payments"])
      assert msg =~ "quote requires a delimiter"
    end
  end

  describe "allow" do
    test "strips characters outside the class before padding" do
      spec = %{
        "renderer" => "text",
        "line_ending" => "\n",
        "sections" => [
          %{
            "kind" => "detail",
            "source" => "payments",
            "fields" => [%{"expr" => "name", "width" => 12, "allow" => "A-Za-z0-9 "}]
          }
        ]
      }

      assert {:ok, "Tan  Sons M \n"} =
               FileSpec.render(spec, [%{"name" => "Tan & Sons (M)"}], %{}, ["name"], ["payments"])
    end

    test "an invalid class is rejected" do
      spec =
        delimited([
          %{
            "kind" => "detail",
            "source" => "payments",
            "fields" => [%{"expr" => "name", "allow" => "z-a"}]
          }
        ])

      assert {:error, [msg]} = FileSpec.validate(spec, ["name"], ["payments"])
      assert msg =~ "allow is not a valid character class"
    end
  end

  describe "filename" do
    test "renders values, dates and a padded sequence" do
      spec = %{"filename" => "PAYMENT_{corporate_id}_{today:%d%m%Y}_{seq:3}.CSV"}
      ctx = %{"corporate_id" => "123456", "today" => ~D[2026-10-12]}
      assert FileSpec.filename(spec, ctx, 7) == "PAYMENT_123456_12102026_007.CSV"
      assert FileSpec.filename(spec, ctx, nil) == "PAYMENT_123456_12102026_.CSV"
    end

    test "drops unsafe characters from inserted values" do
      assert FileSpec.filename(%{"filename" => "{acct}PM.txt"}, %{"acct" => "3123 456/789"}, 1) ==
               "3123456789PM.txt"
    end

    test "a sequence wider than its digits raises" do
      assert_raise ArgumentError, ~r/does not fit/, fn ->
        FileSpec.filename(%{"filename" => "{seq:2}"}, %{}, 100)
      end
    end

    test "nil without a template" do
      assert FileSpec.filename(%{}, %{}, 1) == nil
    end

    test "unknown names and bad date patterns are rejected" do
      spec =
        delimited([%{"kind" => "header", "fields" => [%{"expr" => "1"}]}], %{
          "filename" => "{nope}_{d:%Q}_{seq:2}.txt"
        })

      assert {:error, msgs} = FileSpec.validate(spec, ["d"], ["payments"])
      assert Enum.any?(msgs, &(&1 =~ "filename: unknown name 'nope'"))
      assert Enum.any?(msgs, &(&1 =~ "filename: bad date pattern"))
    end
  end

  describe "max_rows" do
    test "reads a positive integer" do
      assert FileSpec.max_rows(%{"max_rows" => 100}) == 100
      assert FileSpec.max_rows(%{}) == nil
    end

    test "rejects anything else" do
      spec =
        delimited([%{"kind" => "header", "fields" => [%{"expr" => "1"}]}], %{"max_rows" => 0})

      assert {:error, [msg]} = FileSpec.validate(spec, [], ["payments"])
      assert msg =~ "max_rows must be a positive integer"
    end
  end
end
