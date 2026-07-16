defmodule FullCircle.PayScriptTest do
  use ExUnit.Case, async: true

  alias FullCircle.PayScript
  alias FullCircle.PayScript.Error
  alias FullCircle.PayScriptStubEnv

  @socso_rows [
    [2900.0, 3000.0, 51.65, 14.75, 36.9, 22.15],
    [3000.0, 3100.0, 53.35, 15.25, 38.1, 22.85]
  ]

  defp env(overrides \\ %{}) do
    state =
      Map.merge(
        %{
          tables: %{
            "socso" => %{
              columns: [
                "wage_from",
                "wage_to",
                "employer",
                "employee",
                "employer_only",
                "employee_24hour"
              ],
              rows: @socso_rows
            }
          },
          ytd: %{},
          calcs: %{"epf_employee" => 550.0}
        },
        overrides
      )

    {PayScriptStubEnv, state}
  end

  test "standard_variables lists the spec's context variables" do
    assert PayScript.standard_variables() ==
             ~w(wages bonus age malaysian nationality marital_status partner_working children pay_month pay_year service_years)
  end

  test "eval returns a Decimal" do
    assert {:ok, dec} = PayScript.eval("result = 1 + 1", %{}, env())
    assert Decimal.equal?(dec, Decimal.new("2"))
  end

  test "lookup finds the bracket row and column" do
    assert {:ok, dec} =
             PayScript.eval(
               ~s|result = lookup("socso", wages, "employee")|,
               %{"wages" => 2950.0},
               env()
             )

    assert Decimal.equal?(dec, Decimal.new("14.75"))
  end

  test "lookup boundary: value equal to wage_to belongs to the lower bracket" do
    assert {:ok, dec} =
             PayScript.eval(
               ~s|result = lookup("socso", wages, "employee")|,
               %{"wages" => 3000.0},
               env()
             )

    assert Decimal.equal?(dec, Decimal.new("14.75"))
  end

  test "lookup outside all brackets returns 0.0" do
    assert {:ok, dec} =
             PayScript.eval(
               ~s|result = lookup("socso", wages, "employee")|,
               %{"wages" => 99_999.0},
               env()
             )

    assert Decimal.equal?(dec, Decimal.new("0"))
  end

  test "lookup unknown table or column errors" do
    assert {:error, %Error{message: msg}} =
             PayScript.eval(~s|result = lookup("nope", 1, "employee")|, %{}, env())

    assert msg =~ "unknown table 'nope'"

    assert {:error, %Error{message: msg}} =
             PayScript.eval(~s|result = lookup("socso", 1, "nope")|, %{}, env())

    assert msg =~ "unknown column 'nope'"
  end

  test "ytd_sum with single string and with list keys" do
    e = env(%{ytd: %{{:type, ["Addition"]} => 25_000.0, {:name, ["A", "B"]} => 400.0}})

    assert {:ok, dec} = PayScript.eval(~s|result = ytd_sum(type: "Addition")|, %{}, e)
    assert Decimal.equal?(dec, Decimal.new("25000"))

    assert {:ok, dec} = PayScript.eval(~s|result = ytd_sum(name: ["A", "B"])|, %{}, e)
    assert Decimal.equal?(dec, Decimal.new("400"))
  end

  test "ytd_sum for unknown key defaults to 0" do
    assert {:ok, dec} = PayScript.eval(~s|result = ytd_sum(code: "whatever")|, %{}, env())
    assert Decimal.equal?(dec, Decimal.new("0"))
  end

  test "calc resolves other calcs and errors for unknown codes" do
    assert {:ok, dec} = PayScript.eval(~s|result = calc("epf_employee") * 2|, %{}, env())
    assert Decimal.equal?(dec, Decimal.new("1100"))

    assert {:error, %Error{binding: "result", message: msg}} =
             PayScript.eval(~s|result = calc("missing")|, %{}, env())

    assert msg =~ "unknown calc 'missing'"
  end

  test "non-numeric result is an error" do
    assert {:error, %Error{binding: "result", message: msg}} =
             PayScript.eval(~s(result = "abc"), %{}, env())

    assert msg =~ "result must be a number"
  end

  test "parse errors pass through eval" do
    assert {:error, %Error{}} = PayScript.eval("result = 1 +", %{}, env())
  end

  test "eval accepts pre-parsed bindings" do
    {:ok, bindings} = PayScript.parse("result = 2 * 3")
    assert {:ok, dec} = PayScript.eval(bindings, %{}, env())
    assert Decimal.equal?(dec, Decimal.new("6"))
  end

  test "parse_expression parses a single expression" do
    assert {:ok, {:binop, :add, {:num, 1.0}, {:num, 2.0}}} = PayScript.parse_expression("1 + 2")
  end

  test "parse_expression errors on trailing tokens" do
    assert {:error, %Error{message: msg}} = PayScript.parse_expression("1 + 2 foo")
    assert msg =~ "expected end of expression"
  end

  test "eval_expression returns raw values without Decimal coercion" do
    assert {:ok, "ALI"} =
             PayScript.eval_expression(~s|upper(name)|, %{"name" => "ali"}, nil)
  end
end
