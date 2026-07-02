defmodule Mix.Tasks.Statutory.GenTemplate do
  @shortdoc "Generate priv/statutory_templates/malaysia.json from legacy statutory tables"
  @moduledoc false

  use Mix.Task

  alias FullCircle.SalaryNoteCalFunc

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

  @socso_employer_script """
  result = if(age >= 60, lookup("socso", wages, "employer_only"), lookup("socso", wages, "employer"))
  """

  @socso_employer_only_script """
  result = lookup("socso", wages, "employer_only")
  """

  @socso_24hour_script """
  result = lookup("socso", wages, "employee_24hour")
  """

  @eis_employer_script """
  result = if(age < 60 and malaysian, lookup("eis", wages, "employer"), 0)
  """

  @eis_employee_script """
  result = if(age < 60 and malaysian, lookup("eis", wages, "employee"), 0)
  """

  @eis_employer_only_script """
  result = lookup("eis", wages, "employer")
  """

  @id_number_expr ~s|replace(if(socso_no == "" or socso_no == "-", id_no, socso_no), "-", "")|

  @socso_txt_spec %{
    "renderer" => "text",
    "line_ending" => "\r\n",
    "sections" => [
      %{
        "kind" => "detail",
        "source" => "statutory_rows",
        "filter" => "socso_employer > 0 or socso_employee > 0 or socso_employer_only > 0",
        "sort" => "name",
        "fields" => [
          %{"expr" => "employer_code", "width" => 12},
          %{"expr" => ~s|""|, "width" => 20},
          %{"expr" => @id_number_expr, "width" => 12},
          %{"expr" => "upper(name)", "width" => 150},
          %{"expr" => "pay_month", "width" => 2, "format" => "decimal:0", "pad" => "0", "align" => "right"},
          %{"expr" => "pay_year", "width" => 4, "format" => "decimal:0", "pad" => "0", "align" => "right"},
          %{
            "expr" => "socso_employer + socso_employee + socso_employer_only",
            "width" => 14,
            "format" => "cents",
            "pad" => "0",
            "align" => "right"
          },
          %{"expr" => ~s|""|, "width" => 9}
        ]
      }
    ]
  }

  @eis_txt_spec %{
    "renderer" => "text",
    "line_ending" => "\r\n",
    "sections" => [
      %{
        "kind" => "detail",
        "source" => "statutory_rows",
        "filter" => "eis_employer > 0 or eis_employee > 0 or eis_employer_only > 0",
        "sort" => "name",
        "fields" => [
          %{"expr" => "employer_code", "width" => 12},
          %{"expr" => ~s|""|, "width" => 20},
          %{"expr" => @id_number_expr, "width" => 12},
          %{"expr" => "upper(name)", "width" => 150},
          %{"expr" => "pay_month", "width" => 2, "format" => "decimal:0", "pad" => "0", "align" => "right"},
          %{"expr" => "pay_year", "width" => 4, "format" => "decimal:0", "pad" => "0", "align" => "right"},
          %{
            "expr" => "eis_employer + eis_employee + eis_employer_only",
            "width" => 14,
            "format" => "cents",
            "pad" => "0",
            "align" => "right"
          },
          %{"expr" => ~s|""|, "width" => 9}
        ]
      }
    ]
  }

  @epf_form_a_spec %{
    "renderer" => "text",
    "line_ending" => "\r\n",
    "delimiter" => ",",
    "sections" => [
      %{
        "kind" => "detail",
        "source" => "statutory_rows",
        "filter" => "epf_employer > 0 or epf_employee > 0",
        "sort" => "name",
        "fields" => [
          %{"expr" => "epf_no"},
          %{"expr" => "id_no"},
          %{"expr" => "name"},
          %{"expr" => "wages", "format" => "decimal:2"},
          %{"expr" => "round(epf_employer, 0)", "format" => "decimal:0"},
          %{"expr" => "round(epf_employee, 0)", "format" => "decimal:0"}
        ]
      }
    ]
  }

  @socso_eis_txt_spec %{
    "renderer" => "text",
    "line_ending" => "\r\n",
    "sections" => [
      %{
        "kind" => "detail",
        "source" => "statutory_rows",
        "filter" =>
          "socso_employer > 0 or socso_employee > 0 or socso_employer_only > 0 or eis_employer > 0 or eis_employee > 0 or eis_employer_only > 0 or socso_24hour > 0",
        "sort" => "name",
        "fields" => [
          %{"expr" => "employer_code", "width" => 12},
          %{"expr" => ~s|""|, "width" => 20},
          %{"expr" => @id_number_expr, "width" => 12},
          %{"expr" => "upper(name)", "width" => 150},
          %{"expr" => "pay_month", "width" => 2, "format" => "decimal:0", "pad" => "0", "align" => "right"},
          %{"expr" => "pay_year", "width" => 4, "format" => "decimal:0", "pad" => "0", "align" => "right"},
          %{"expr" => "wages", "width" => 14, "format" => "cents", "pad" => "0", "align" => "right"},
          %{
            "expr" => "socso_employer + socso_employer_only",
            "width" => 6,
            "format" => "cents",
            "pad" => "0",
            "align" => "right"
          },
          %{"expr" => "socso_employee", "width" => 6, "format" => "cents", "pad" => "0", "align" => "right"},
          %{
            "expr" => "eis_employer + eis_employer_only",
            "width" => 6,
            "format" => "cents",
            "pad" => "0",
            "align" => "right"
          },
          %{"expr" => "eis_employee", "width" => 6, "format" => "cents", "pad" => "0", "align" => "right"},
          %{"expr" => "socso_24hour", "width" => 6, "format" => "cents", "pad" => "0", "align" => "right"},
          %{"expr" => ~s|""|, "width" => 34}
        ]
      }
    ]
  }

  @pcb_cp39_spec %{
    "renderer" => "text",
    "line_ending" => "\r\n",
    "sections" => [
      %{
        "kind" => "header",
        "fields" => [
          %{"expr" => ~s|"H"|, "width" => 1},
          %{"expr" => "employer_code", "width" => 10, "format" => "digits", "pad" => "0", "align" => "right"},
          %{"expr" => "employer_code", "width" => 10, "format" => "digits", "pad" => "0", "align" => "right"},
          %{"expr" => "pay_year", "width" => 4, "format" => "digits", "pad" => "0", "align" => "right"},
          %{"expr" => "pay_month", "width" => 2, "format" => "digits", "pad" => "0", "align" => "right"},
          %{"expr" => ~s|sum("pcb_employee")|, "width" => 10, "format" => "cents", "pad" => "0", "align" => "right"},
          %{"expr" => "count()", "width" => 5, "format" => "decimal:0", "pad" => "0", "align" => "right"},
          %{"expr" => "0", "width" => 10, "format" => "decimal:0", "pad" => "0", "align" => "right"},
          %{"expr" => "0", "width" => 5, "format" => "decimal:0", "pad" => "0", "align" => "right"}
        ]
      },
      %{
        "kind" => "detail",
        "source" => "statutory_rows",
        "filter" => "pcb_employee > 0",
        "sort" => "name",
        "fields" => [
          %{"expr" => ~s|"D"|, "width" => 1},
          %{"expr" => "tax_no", "width" => 11, "format" => "digits", "pad" => "0", "align" => "right"},
          %{"expr" => "name", "width" => 60},
          %{"expr" => ~s|""|, "width" => 12},
          %{"expr" => "id_no", "width" => 12, "format" => "digits"},
          %{"expr" => ~s|""|, "width" => 12},
          %{"expr" => ~s|"MY"|, "width" => 2},
          %{"expr" => "pcb_employee", "width" => 8, "format" => "cents", "pad" => "0", "align" => "right"},
          %{"expr" => "0", "width" => 8, "format" => "decimal:0", "pad" => "0", "align" => "right"},
          %{"expr" => ~s|""|, "width" => 10}
        ]
      }
    ]
  }

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

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    bundle = %{
      "bundle_version" => 1,
      "source" => "legacy SalaryNoteCalFunc + pay_script_acceptance_test reference scripts",
      "rate_tables" => [
        table_entry("socso", ~D[1957-01-01],
          ["wage_from", "wage_to", "employer", "employee", "employer_only", "employee_24hour"],
          SalaryNoteCalFunc.socso_table()
        ),
        table_entry("eis", ~D[1957-01-01],
          ["wage_from", "wage_to", "employer", "employee", "total"],
          SalaryNoteCalFunc.eis_table()
        ),
        table_entry("pcb_normal", ~D[1957-01-01],
          ["p_from", "p_to", "m", "r", "b13", "b2"],
          SalaryNoteCalFunc.pcb_table_normal()
        )
      ],
      "calcs" => [
        constant_calc("epf_relief_cap", "EPF Relief Cap", ~D[1957-01-01], 4000),
        constant_calc("pcb_individual_deduction", "PCB Individual Deduction", ~D[1957-01-01], 9000),
        constant_calc("pcb_spouse_deduction", "PCB Spouse Deduction", ~D[1957-01-01], 4000),
        constant_calc("pcb_child_deduction", "PCB Child Deduction", ~D[1957-01-01], 2000),
        calc_entry("epf_employer", "EPF Employer", ~D[1957-01-01], @epf_employer_script),
        calc_entry("epf_employee", "EPF Employee", ~D[1957-01-01], @epf_employee_script),
        calc_entry("socso_employer", "SOCSO Employer", ~D[1957-01-01], @socso_employer_script),
        calc_entry("socso_employee", "SOCSO Employee", ~D[1957-01-01], @socso_employee_script),
        calc_entry("socso_employer_only", "SOCSO Employer Only", ~D[1957-01-01], @socso_employer_only_script),
        calc_entry("socso_24hour", "SOCSO 24 Hour (SKBBK)", ~D[2026-06-01], @socso_24hour_script),
        calc_entry("eis_employer", "EIS Employer", ~D[1957-01-01], @eis_employer_script),
        calc_entry("eis_employee", "EIS Employee", ~D[1957-01-01], @eis_employee_script),
        calc_entry("eis_employer_only", "EIS Employer Only", ~D[1957-01-01], @eis_employer_only_script),
        calc_entry("pcb_employee", "PCB Employee", ~D[1957-01-01], @pcb_script)
      ],
      "file_formats" => [
        file_format_entry("socso_txt", "SOCSO text file", ~D[1957-01-01], @socso_txt_spec),
        file_format_entry("eis_txt", "EIS text file", ~D[1957-01-01], @eis_txt_spec),
        file_format_entry("epf_form_a", "EPF Form A", ~D[1957-01-01], @epf_form_a_spec),
        file_format_entry("socso_eis_txt", "SOCSO+EIS text file", ~D[1957-01-01], @socso_eis_txt_spec),
        file_format_entry("pcb_cp39", "PCB CP39", ~D[1957-01-01], @pcb_cp39_spec)
      ]
    }

    path = Path.join([File.cwd!(), "priv", "statutory_templates", "malaysia.json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(bundle, pretty: true) <> "\n")
    Mix.shell().info("Wrote #{path}")
  end

  defp table_entry(code, date, columns, rows) do
    %{
      "code" => code,
      "effective_from" => Date.to_iso8601(date),
      "columns" => columns,
      "rows" => Enum.map(rows, fn row -> Enum.map(row, &to_float/1) end)
    }
  end

  defp calc_entry(code, name, date, script) do
    %{
      "code" => code,
      "name" => name,
      "effective_from" => Date.to_iso8601(date),
      "script" => String.trim_trailing(script)
    }
  end

  defp constant_calc(code, name, date, value) do
    calc_entry(code, name, date, "result = #{value}")
  end

  defp file_format_entry(code, name, date, spec) do
    %{
      "code" => code,
      "name" => name,
      "effective_from" => Date.to_iso8601(date),
      "renderer" => "text",
      "spec" => spec
    }
  end

  defp to_float(n) when is_integer(n), do: n * 1.0
  defp to_float(n) when is_float(n), do: n
end