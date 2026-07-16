defmodule FullCircle.PayScript.ValidatorTest do
  use ExUnit.Case, async: true

  alias FullCircle.PayScript
  alias FullCircle.PayScript.Error

  @schema %{
    tables: %{"socso" => ["wage_from", "wage_to", "employer", "employee"]},
    calcs: ["epf_employee", "epf_relief_cap"]
  }

  defp errors(source, schema \\ @schema) do
    {:error, errs} = PayScript.validate(source, schema)
    Enum.map(errs, &Exception.message/1)
  end

  test "a correct script validates" do
    script = """
    base = wages + bonus
    result = if(age >= 60, 0, lookup("socso", base, "employee"))
    """

    assert :ok = PayScript.validate(script, @schema)
  end

  test "standard variables are known by default; unknown identifiers are reported per binding" do
    assert ["in 'result': unknown identifier 'wage'"] = errors("result = wage + 1")
  end

  test "bindings can reference earlier bindings but not later ones" do
    assert :ok = PayScript.validate("a = wages\nresult = a", @schema)
    assert ["in 'a': unknown identifier 'b'" | _] = errors("a = b\nb = 1\nresult = a")
  end

  test "unknown function and wrong builtin arity" do
    assert ["in 'result': unknown function 'sqrt'"] = errors("result = sqrt(4)")
    assert ["in 'result': min() takes 2 argument(s), got 1"] = errors("result = min(1)")
  end

  test "lookup table and column must be literals that exist" do
    assert ["in 'result': unknown table 'nope'"] =
             errors(~s|result = lookup("nope", 1, "employee")|)

    assert ["in 'result': unknown column 'nope' in table 'socso'"] =
             errors(~s|result = lookup("socso", 1, "nope")|)

    assert ["in 'result': lookup() table and column must be string literals"] =
             errors(~s|result = lookup("so" + "cso", 1, "employee")|)
  end

  test "without schema tables, lookup literals are not checked" do
    assert :ok = PayScript.validate(~s|result = lookup("anything", 1, "col")|, %{})
  end

  test "ytd_sum argument shape" do
    assert :ok = PayScript.validate(~s|result = ytd_sum(code: "x")|, %{})
    assert :ok = PayScript.validate(~s|result = ytd_sum(name: ["a", "b"])|, %{})

    assert ["in 'result': ytd_sum expects a single 'code:', 'type:' or 'name:' argument"] =
             errors(~s|result = ytd_sum("x")|, %{})

    assert ["in 'result': ytd_sum name: must be a string or list of strings"] =
             errors(~s|result = ytd_sum(name: [1])|, %{})
  end

  test "calc code checked against schema when given" do
    assert :ok = PayScript.validate(~s|result = calc("epf_employee")|, @schema)
    assert ["in 'result': unknown calc 'nope'"] = errors(~s|result = calc("nope")|)

    assert ["in 'result': calc() argument must be a string literal"] =
             errors("result = calc(wages)", %{})
  end

  test "multiple errors are all collected" do
    errs = errors("a = boom\nresult = sqrt(a)")
    assert length(errs) == 2
  end

  test "parse errors come back as a single-element error list" do
    assert {:error, [%Error{}]} = PayScript.validate("result = 1 +", %{})
  end

  test "calc_deps returns unique referenced codes" do
    script = """
    a = calc("epf_employee") + calc("epf_relief_cap")
    result = a + calc("epf_employee")
    """

    assert {:ok, deps} = PayScript.calc_deps(script)
    assert Enum.sort(deps) == ["epf_employee", "epf_relief_cap"]
  end

  test "check_cycles passes an acyclic set" do
    assert :ok =
             PayScript.check_cycles(%{
               "pcb_employee" => "result = calc(\"epf_employee\")",
               "epf_employee" => "result = wages * 0.11"
             })
  end

  test "check_cycles reports a cycle" do
    assert {:error, %Error{message: msg}} =
             PayScript.check_cycles(%{
               "a" => "result = calc(\"b\")",
               "b" => "result = calc(\"a\")"
             })

    assert msg =~ "calc cycle:"
  end

  test "check_cycles reports self-reference" do
    assert {:error, %Error{message: msg}} =
             PayScript.check_cycles(%{"a" => "result = calc(\"a\")"})

    assert msg =~ "calc cycle:"
  end

  test "check_cycles reports references to missing calcs" do
    assert {:error, %Error{message: msg}} =
             PayScript.check_cycles(%{"a" => "result = calc(\"ghost\")"})

    assert msg =~ "references unknown calc 'ghost'"
  end

  test "check_cycles reports which calc failed to parse" do
    assert {:error, %Error{message: msg}} = PayScript.check_cycles(%{"bad" => "result = 1 +"})
    assert msg =~ "in calc 'bad'"
  end

  test "validate_expression accepts string builtins" do
    schema = %{variables: ["name", "id"]}

    for expr <- [~s|upper(name)|, ~s|lower(name)|, ~s|trim(name)|, ~s|replace(id, "-", "")|] do
      assert :ok = PayScript.validate_expression(expr, schema)
    end
  end

  test "validate_expression rejects wrong builtin arity" do
    assert {:error, [%Error{message: msg}]} =
             PayScript.validate_expression(~s|replace(name)|, %{variables: ["name"]})

    assert msg =~ "replace()"
  end
end
