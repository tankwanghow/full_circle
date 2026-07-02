defmodule FullCircle.PayScriptAcceptanceTest do
  use ExUnit.Case, async: true

  alias FullCircle.PayScript
  alias FullCircle.PayScriptStubEnv

  @socso %{
    columns: ["wage_from", "wage_to", "employer", "employee", "employer_only", "employee_24hour"],
    rows: [
      [2900.0, 3000.0, 51.65, 14.75, 36.9, 22.15],
      [4900.0, 5000.0, 86.65, 24.75, 61.9, 37.15],
      [6000.0, 999_999.0, 104.15, 29.75, 74.4, 44.65]
    ]
  }

  @pcb_normal %{
    columns: ["p_from", "p_to", "m", "r", "b13", "b2"],
    rows: [
      [5001.0, 20_000.0, 5000.0, 0.01, -400.0, -800.0],
      [20_001.0, 35_000.0, 20_000.0, 0.03, -250.0, -650.0],
      [35_001.0, 50_000.0, 35_000.0, 0.06, 600.0, 600.0],
      [50_001.0, 70_000.0, 50_000.0, 0.11, 1500.0, 1500.0],
      [70_001.0, 100_000.0, 70_000.0, 0.19, 3700.0, 3700.0],
      [100_001.0, 400_000.0, 100_000.0, 0.25, 9400.0, 9400.0],
      [400_001.0, 600_000.0, 400_000.0, 0.26, 84_400.0, 84_400.0],
      [600_001.0, 2_000_000.0, 600_000.0, 0.28, 136_400.0, 136_400.0],
      [2_000_000.01, 999_999_999.0, 2_000_000.0, 0.3, 528_400.0, 528_400.0]
    ]
  }

  @epf_employer_script """
  total = wages + bonus
  rate = if(total <= 10, 0,
         if(not malaysian, 0.02,
         if(age >= 60, 0.04,
         if(total <= 5000, 0.13, 0.12))))
  result = ceil(total * rate)
  """

  @epf_employee_script """
  total = wages + bonus
  rate = if(total <= 10, 0,
         if(not malaysian, 0.02,
         if(age >= 60, 0, 0.11)))
  result = ceil(total * rate)
  """

  @socso_employee_script """
  result = if(age >= 60, 0, lookup("socso", wages, "employee"))
  """

  @socso_24hour_script """
  result = lookup("socso", wages, "employee_24hour")
  """

  @pcb_script """
  cap = calc("epf_relief_cap")
  y   = ytd_sum(type: "Addition") + ytd_sum(name: "Employee Current Year Income")
  k   = min(ytd_sum(name: ["EPF By Employee", "EPF By Employee Current Year"]), cap)
  y1  = wages
  k1  = if(k >= cap, 0, min(calc("epf_employee"), cap - k))
  y2  = y1
  n   = 12 - pay_month
  k2  = if(k + k1 == 0, 0, if(k + k1 * n >= cap, 0, cap - (k + k1 * n)))
  yt  = bonus
  kt  = if(k + k1 + k2 == 0, 0,
        if(k + k1 + k2 >= cap, 0, min(calc("epf_employee"), cap - (k + k1 + k2))))
  d   = calc("pcb_individual_deduction")
  s   = if(marital_status == "Married" and not partner_working,
           calc("pcb_spouse_deduction"), 0)
  q   = calc("pcb_child_deduction")
  p   = y - k + (y1 - k1) + (y2 - k2) * n + (yt - kt) - (d + s + q * children)
  m   = lookup("pcb_normal", p, "m")
  r   = lookup("pcb_normal", p, "r")
  b   = if(marital_status == "Married" and not partner_working,
           lookup("pcb_normal", p, "b2"),
           lookup("pcb_normal", p, "b13"))
  x   = ytd_sum(name: ["Employee PCB", "PCB Current Year"])
  z   = ytd_sum(name: ["Employee Zakat", "Zakat Current Year"])
  pcb = ((p - m) * r + b - (z + x)) / (n + 1)
  result = if(pcb > 0, round(pcb, 1), 0)
  """

  defp context(overrides \\ %{}) do
    Map.merge(
      %{
        "wages" => 5000.0,
        "bonus" => 0.0,
        "age" => 35,
        "malaysian" => true,
        "nationality" => "Malaysian",
        "marital_status" => "Married",
        "partner_working" => false,
        "children" => 2,
        "pay_month" => 6,
        "pay_year" => 2026,
        "service_years" => 10
      },
      overrides
    )
  end

  defp env(overrides \\ %{}) do
    state =
      Map.merge(
        %{
          tables: %{"socso" => @socso, "pcb_normal" => @pcb_normal},
          ytd: %{
            {:type, ["Addition"]} => 25_000.0,
            {:name, ["EPF By Employee", "EPF By Employee Current Year"]} => 2_750.0,
            {:name, ["Employee PCB", "PCB Current Year"]} => 400.0
          },
          calcs: %{
            "epf_employee" => 550.0,
            "epf_relief_cap" => 4_000.0,
            "pcb_individual_deduction" => 9_000.0,
            "pcb_spouse_deduction" => 4_000.0,
            "pcb_child_deduction" => 2_000.0
          }
        },
        overrides
      )

    {PayScriptStubEnv, state}
  end

  defp assert_eval(script, ctx, env_tuple, expected) do
    assert {:ok, dec} = PayScript.eval(script, ctx, env_tuple)

    assert Decimal.equal?(dec, Decimal.new(expected)),
           "expected #{expected}, got #{Decimal.to_string(dec)}"
  end

  test "all reference scripts pass validation with a full schema" do
    schema = %{
      tables: %{
        "socso" => @socso.columns,
        "pcb_normal" => @pcb_normal.columns
      },
      calcs: ~w(epf_employee epf_relief_cap pcb_individual_deduction
                pcb_spouse_deduction pcb_child_deduction)
    }

    for script <- [
          @epf_employer_script,
          @epf_employee_script,
          @socso_employee_script,
          @socso_24hour_script,
          @pcb_script
        ] do
      assert :ok = PayScript.validate(script, schema)
    end
  end

  describe "epf_employer (parity with calculate_value(:epf_employer, ...))" do
    test "malaysian under 60, wages <= 5000 -> 13%" do
      assert_eval(@epf_employer_script, context(), env(), "650.0")
    end

    test "malaysian under 60, wages > 5000 -> 12%" do
      assert_eval(@epf_employer_script, context(%{"wages" => 6000.0}), env(), "720.0")
    end

    test "malaysian 60+ -> 4%" do
      assert_eval(@epf_employer_script, context(%{"age" => 60}), env(), "200.0")
    end

    test "non-malaysian (any age) -> 2%" do
      assert_eval(
        @epf_employer_script,
        context(%{"malaysian" => false, "age" => 65}),
        env(),
        "100.0"
      )
    end

    test "income <= 10 -> 0" do
      assert_eval(@epf_employer_script, context(%{"wages" => 10.0}), env(), "0.0")
    end
  end

  describe "epf_employee (parity with calculate_value(:epf_employee, ...))" do
    test "malaysian under 60 -> 11%" do
      assert_eval(@epf_employee_script, context(), env(), "550.0")
    end

    test "malaysian 60+ -> 0" do
      assert_eval(@epf_employee_script, context(%{"age" => 61}), env(), "0.0")
    end

    test "non-malaysian -> 2%" do
      assert_eval(@epf_employee_script, context(%{"malaysian" => false}), env(), "100.0")
    end
  end

  describe "socso scripts (parity with socso_table lookups)" do
    test "socso_employee at wages 2950 -> 14.75; 60+ -> 0" do
      assert_eval(@socso_employee_script, context(%{"wages" => 2950.0}), env(), "14.75")
      assert_eval(@socso_employee_script, context(%{"wages" => 2950.0, "age" => 60}), env(), "0.0")
    end

    test "socso_24hour applies regardless of age, ceiling bracket above 6000" do
      assert_eval(@socso_24hour_script, context(%{"wages" => 2950.0, "age" => 61}), env(), "22.15")
      assert_eval(@socso_24hour_script, context(%{"wages" => 20_000.0}), env(), "44.65")
    end
  end

  describe "pcb_employee (parity with calculate_value(:pcb_employee, ...))" do
    test "married, partner not working, 2 children, mid-year" do
      assert_eval(@pcb_script, context(), env(), "64.1")
    end

    test "negative PCB clamps to 0" do
      low_env =
        env(%{
          ytd: %{
            {:type, ["Addition"]} => 0.0,
            {:name, ["EPF By Employee", "EPF By Employee Current Year"]} => 0.0,
            {:name, ["Employee PCB", "PCB Current Year"]} => 400.0
          },
          calcs: %{
            "epf_employee" => 110.0,
            "epf_relief_cap" => 4_000.0,
            "pcb_individual_deduction" => 9_000.0,
            "pcb_spouse_deduction" => 4_000.0,
            "pcb_child_deduction" => 2_000.0
          }
        })

      assert_eval(@pcb_script, context(%{"wages" => 1000.0}), low_env, "0.0")
    end

    test "runtime error in December is avoided: n + 1 = 1, no division by zero" do
      assert {:ok, _dec} = PayScript.eval(@pcb_script, context(%{"pay_month" => 12}), env())
    end
  end

  test "a genuinely broken script surfaces a named runtime error" do
    assert {:error, err} =
             PayScript.eval("boom = 1 / (wages - wages)\nresult = boom", context(), env())

    assert Exception.message(err) == "in 'boom': division by zero"
  end
end