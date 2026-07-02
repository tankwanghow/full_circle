defmodule FullCircle.FileSpecTest do
  use ExUnit.Case, async: true

  alias FullCircle.FileSpec

  @variables ~w(name id_no wages socso_employee socso_employer employer_code pay_month pay_year)

  defp socso_spec(overrides \\ %{}) do
    Map.merge(
      %{
        "renderer" => "text",
        "line_ending" => "\r\n",
        "sections" => [
          %{
            "kind" => "detail",
            "source" => "statutory_rows",
            "filter" => "socso_employee > 0",
            "sort" => "name",
            "fields" => [
              %{"expr" => "employer_code", "width" => 4},
              %{"expr" => "name", "width" => 6},
              %{"expr" => "socso_employee", "width" => 5, "format" => "cents", "pad" => "0", "align" => "right"}
            ]
          }
        ]
      },
      overrides
    )
  end

  describe "validate/2" do
    test "accepts a minimal fixed-width spec" do
      assert :ok = FileSpec.validate(socso_spec(), @variables)
    end

    test "requires non-empty sections" do
      assert {:error, msgs} = FileSpec.validate(%{"renderer" => "text", "sections" => []}, @variables)
      assert Enum.any?(msgs, &(&1 =~ "sections"))
    end

    test "rejects unknown section kind" do
      spec = put_in(socso_spec()["sections"], [%{"kind" => "body", "fields" => [%{"expr" => "1", "width" => 1}]}])

      assert {:error, [msg]} = FileSpec.validate(spec, @variables)
      assert msg =~ "kind"
    end

    test "detail requires statutory_rows source" do
      spec =
        put_in(socso_spec()["sections"], [
          %{"kind" => "detail", "source" => "rows", "fields" => [%{"expr" => "1", "width" => 1}]}
        ])

      assert {:error, [msg]} = FileSpec.validate(spec, @variables)
      assert msg =~ "statutory_rows"
    end

    test "delimiter mode forbids field width" do
      spec =
        socso_spec(%{
          "delimiter" => ",",
          "sections" => [
            %{
              "kind" => "detail",
              "source" => "statutory_rows",
              "fields" => [%{"expr" => "name", "width" => 5}]
            }
          ]
        })

      assert {:error, [msg]} = FileSpec.validate(spec, @variables)
      assert msg =~ "width is not allowed"
    end

    test "fixed-width mode requires width" do
      spec =
        put_in(socso_spec()["sections"], [
          %{
            "kind" => "detail",
            "source" => "statutory_rows",
            "fields" => [%{"expr" => "name"}]
          }
        ])

      assert {:error, [msg]} = FileSpec.validate(spec, @variables)
      assert msg =~ "width is required"
    end

    test "rejects aggregates in detail expressions" do
      spec =
        put_in(socso_spec()["sections"], [
          %{
            "kind" => "detail",
            "source" => "statutory_rows",
            "fields" => [%{"expr" => "count()", "width" => 3}]
          }
        ])

      assert {:error, [msg]} = FileSpec.validate(spec, @variables)
      assert msg =~ "aggregate"
    end

    test "prefixes expression errors with section and field index" do
      spec =
        put_in(socso_spec()["sections"], [
          %{
            "kind" => "detail",
            "source" => "statutory_rows",
            "fields" => [
              %{"expr" => "name", "width" => 3},
              %{"expr" => "missing_var", "width" => 3}
            ]
          }
        ])

      assert {:error, [msg]} = FileSpec.validate(spec, @variables)
      assert msg =~ "section 1, field 2"
    end
  end

  describe "render/3" do
    test "fixed-width padding and cents rounding" do
      rows = [
        %{name: "ali", socso_employee: Decimal.new("14.75")},
        %{name: "bob", socso_employee: Decimal.new("0")}
      ]

      ctx = %{"employer_code" => "AB"}

      assert {:ok, text} = FileSpec.render(socso_spec(), rows, ctx)
      assert text == "AB  ali   01475\r\n"
    end

    test "filter excludes rows and sort orders by name" do
      spec =
        socso_spec(%{
          "sections" => [
            %{
              "kind" => "detail",
              "source" => "statutory_rows",
              "filter" => "socso_employee > 0",
              "sort" => "name",
              "fields" => [%{"expr" => "name", "width" => 4}]
            }
          ]
        })

      rows = [
        %{name: "zed", socso_employee: 1},
        %{name: "amy", socso_employee: 0},
        %{name: "bob", socso_employee: 2}
      ]

      assert {:ok, "bob \r\nzed \r\n"} = FileSpec.render(spec, rows, %{})
    end

    test "detail rows see employer_code from header context" do
      rows = [%{name: "amy", socso_employee: 1}]
      assert {:ok, "CODEamy   00100\r\n"} = FileSpec.render(socso_spec(), rows, %{"employer_code" => "CODE"})
    end

    test "delimited mode joins fields" do
      spec = %{
        "renderer" => "text",
        "line_ending" => "\n",
        "delimiter" => ",",
        "sections" => [
          %{
            "kind" => "detail",
            "source" => "statutory_rows",
            "fields" => [
              %{"expr" => "name"},
              %{"expr" => "wages", "format" => "decimal:2"}
            ]
          }
        ]
      }

      rows = [%{name: "amy", wages: 3000.0}]
      assert {:ok, "amy,3000.00\n"} = FileSpec.render(spec, rows, %{})
    end

    test "footer sum and count over filtered detail rows" do
      spec = %{
        "renderer" => "text",
        "line_ending" => "\n",
        "sections" => [
          %{
            "kind" => "detail",
            "source" => "statutory_rows",
            "filter" => "socso_employee > 0",
            "fields" => [%{"expr" => "name", "width" => 4}]
          },
          %{
            "kind" => "footer",
            "fields" => [
              %{"expr" => "count()", "width" => 2, "format" => "decimal:0", "pad" => "0", "align" => "right"},
              %{"expr" => "sum(\"socso_employee\")", "width" => 5, "format" => "cents", "pad" => "0", "align" => "right"}
            ]
          }
        ]
      }

      rows = [
        %{name: "amy", socso_employee: 1.5},
        %{name: "bob", socso_employee: 0},
        %{name: "zed", socso_employee: 2.25}
      ]

      assert {:ok, "amy \nzed \n0200375\n"} = FileSpec.render(spec, rows, %{})
    end

    test "left-aligned overflow truncates on the right" do
      spec =
        put_in(socso_spec()["sections"], [
          %{
            "kind" => "detail",
            "source" => "statutory_rows",
            "fields" => [%{"expr" => "name", "width" => 3}]
          }
        ])

      assert {:ok, "ali\r\n"} = FileSpec.render(spec, [%{name: "alice"}], %{})
    end

    test "right-aligned numeric overflow is an error" do
      spec =
        put_in(socso_spec()["sections"], [
          %{
            "kind" => "detail",
            "source" => "statutory_rows",
            "fields" => [
              %{"expr" => "socso_employee", "width" => 3, "format" => "cents", "pad" => "0", "align" => "right"}
            ]
          }
        ])

      assert {:error, msg} = FileSpec.render(spec, [%{socso_employee: 123.45}], %{})
      assert msg =~ "exceeds width"
    end
  end
end