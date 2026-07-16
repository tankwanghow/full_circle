defmodule FullCircle.StatutoryConfig do
  @moduledoc """
  Per-company, effective-dated statutory configuration: rate tables, PayScript
  calcs and file format specs. See docs/superpowers/specs/2026-07-02-statutory-zero-redeploy-design.md.
  """
  import Ecto.Query, warn: false
  import Ecto.Changeset

  alias Ecto.Multi
  alias FullCircle.{FileSpec, HR, PayScript, Repo, Sys}
  alias FullCircle.HR.{PaySlip, StatutoryCalc, StatutoryFileFormat, StatutoryRateTable}
  alias FullCircle.PayScript.Error
  alias FullCircle.StatutoryConfig.{Cache, DbEnv}

  @kinds %{table: StatutoryRateTable, calc: StatutoryCalc, file_format: StatutoryFileFormat}
  @bundle_version 1
  @template_path "priv/statutory_templates/malaysia.json"

  @report_format_codes %{
    "EPF" => "epf_form_a",
    "SOCSO" => "socso_txt",
    "EIS" => "eis_txt",
    "SOCSO+EIS" => "socso_eis_txt",
    "PCB" => "pcb_cp39"
  }

  def report_format_code(report), do: Map.get(@report_format_codes, report)

  def effective_calc(company_id, code, date), do: effective(:calc, company_id, code, date)
  def effective_table(company_id, code, date), do: effective(:table, company_id, code, date)

  def effective_file_format(company_id, code, date),
    do: effective(:file_format, company_id, code, date)

  defp effective(kind, company_id, code, date) do
    versions(kind, company_id, code)
    |> Enum.find(fn v -> Date.compare(v.effective_from, date) != :gt end)
  end

  defp versions(kind, company_id, code) do
    Cache.fetch({company_id, kind, code}, fn ->
      schema = @kinds[kind]

      from(r in schema,
        where: r.company_id == ^company_id and r.code == ^code,
        order_by: [desc: r.effective_from]
      )
      |> Repo.all()
    end)
  end

  def list_versions(kind, company_id) do
    schema = @kinds[kind]

    from(r in schema,
      where: r.company_id == ^company_id,
      order_by: [asc: r.code, desc: r.effective_from]
    )
    |> Repo.all()
  end

  def calc_codes(company_id) do
    from(c in StatutoryCalc, where: c.company_id == ^company_id, distinct: true, select: c.code)
    |> Repo.all()
  end

  def tables_map(company_id, date) do
    from(t in StatutoryRateTable,
      where: t.company_id == ^company_id,
      distinct: true,
      select: t.code
    )
    |> Repo.all()
    |> Map.new(fn code ->
      case effective_table(company_id, code, date) do
        nil -> {code, []}
        t -> {code, t.columns}
      end
    end)
  end

  def save_rate_table(attrs, company, user, opts \\ []) do
    attrs = put_company(attrs, company)
    base = replace_base(:table, attrs, company, opts)
    save(StatutoryRateTable.changeset(base, attrs), company, user, "statutory_rate_table", attrs)
  end

  def save_file_format(attrs, company, user, opts \\ []) do
    attrs = put_company(attrs, company)
    base = replace_base(:file_format, attrs, company, opts)
    cs = StatutoryFileFormat.changeset(base, attrs)
    cs = if cs.valid?, do: cross_validate_file_format(cs, company), else: cs
    save(cs, company, user, "statutory_file_format", attrs)
  end

  @doc "True when a version with this code and effective date is already saved."
  def version_exists?(kind, company_id, code, effective_from) do
    case parse_bundle_date(effective_from) do
      nil -> false
      date -> find_version(kind, company_id, code, date) != nil
    end
  end

  # With replace: true and a matching (code, effective_from) version, base the
  # changeset on the existing row so save/5 updates it in place.
  defp replace_base(kind, attrs, company, opts) do
    with true <- Keyword.get(opts, :replace, false),
         %Date{} = date <- parse_bundle_date(attrs["effective_from"]),
         %{} = existing <- find_version(kind, company.id, attrs["code"], date) do
      existing
    else
      _ -> struct(@kinds[kind])
    end
  end

  def render_file(company_id, code, month, year, employer_code) do
    date = Timex.end_of_month(year, month)

    case effective_file_format(company_id, code, date) do
      nil ->
        {:error, "no file format '#{code}' configured"}

      %{spec: spec} ->
        rows = HR.statutory_contributions(month, year, company_id)

        header_ctx = %{
          "employer_code" => employer_code,
          "company_name" => company_name(company_id),
          "pay_month" => month,
          "pay_year" => year
        }

        case FileSpec.render(spec, rows, header_ctx) do
          {:ok, text} -> {:ok, {"#{code}_#{month}_#{year}.txt", text}}
          {:error, msg} -> {:error, msg}
        end
    end
  end

  def file_format_variables(company_id) do
    HR.statutory_categories(company_id) ++
      ~w(name id_no tax_no socso_no epf_no wages pay_month pay_year employer_code company_name)
  end

  def save_calc(attrs, company, user, opts \\ []) do
    attrs = put_company(attrs, company)
    base = replace_base(:calc, attrs, company, opts)
    cs = StatutoryCalc.changeset(base, attrs)
    cs = if cs.valid?, do: cross_validate_calc(cs, company), else: cs
    save(cs, company, user, "statutory_calc", attrs)
  end

  defp put_company(attrs, company) do
    attrs |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Map.put("company_id", company.id)
  end

  defp cross_validate_file_format(cs, company) do
    spec = get_field(cs, :spec)

    case FileSpec.validate(spec, file_format_variables(company.id)) do
      :ok ->
        cs

      {:error, errors} ->
        Enum.reduce(errors, cs, &add_error(&2, :spec, &1))
    end
  end

  defp company_name(company_id) do
    case Repo.get(FullCircle.Sys.Company, company_id) do
      %{name: name} -> name
      _ -> ""
    end
  end

  defp cross_validate_calc(cs, company) do
    code = get_field(cs, :code)
    script = get_field(cs, :script)
    date = get_field(cs, :effective_from)

    calc_refs =
      case PayScript.calc_deps(script) do
        {:ok, deps} -> deps
        _ -> []
      end

    schema = %{
      tables: tables_map(company.id, date),
      calcs: Enum.uniq(calc_codes(company.id) ++ [code] ++ calc_refs)
    }

    cs =
      case PayScript.validate(script, schema) do
        :ok ->
          cs

        {:error, errors} ->
          Enum.reduce(errors, cs, &add_error(&2, :script, Exception.message(&1)))
      end

    sources =
      company.id
      |> calc_codes()
      |> Map.new(fn c ->
        {c, (effective_calc(company.id, c, date) || %{script: "result = 0"}).script}
      end)
      |> Map.put(code, script)
      |> add_placeholder_calcs(calc_refs)

    case PayScript.check_cycles(sources) do
      :ok -> cs
      {:error, e} -> add_error(cs, :script, Exception.message(e))
    end
  end

  def script_context(emp, cs) do
    pay_month = fetch_field!(cs, :pay_month)
    pay_year = fetch_field!(cs, :pay_year)
    end_of_month = Timex.end_of_month(pay_year, pay_month)

    %{
      "wages" => cs |> fetch_field!(:addition_amount) |> Decimal.to_float(),
      "bonus" => cs |> fetch_field!(:bonus_amount) |> Decimal.to_float(),
      "age" => Timex.diff(end_of_month, emp.dob, :years),
      "malaysian" =>
        emp.nationality |> String.trim() |> String.downcase() |> String.starts_with?("malays"),
      "nationality" => emp.nationality,
      "marital_status" => emp.marital_status,
      "partner_working" => emp.partner_working in ["true", "Yes"],
      "children" => emp.children,
      "pay_month" => pay_month,
      "pay_year" => pay_year,
      "service_years" =>
        if(emp.service_since,
          do: Timex.diff(end_of_month, emp.service_since, :years),
          else: 0
        )
    }
  end

  def template_bundle do
    path = Application.app_dir(:full_circle, @template_path)

    path
    |> File.read!()
    |> Jason.decode!()
  end

  def validate_bundle(bundle) when is_map(bundle) do
    case validate_bundle_shape(bundle) do
      [] ->
        errors =
          []
          |> validate_bundle_version(bundle)
          |> validate_bundle_entries(bundle)
          |> validate_bundle_calcs(bundle)

        case errors do
          [] -> :ok
          _ -> {:error, Enum.reverse(errors)}
        end

      shape_errors ->
        {:error, shape_errors}
    end
  end

  def validate_bundle(_bundle), do: {:error, ["bundle must be a JSON object"]}

  defp validate_bundle_shape(bundle) do
    Enum.flat_map(~w(rate_tables calcs file_formats), fn key ->
      case bundle[key] do
        nil ->
          []

        list when is_list(list) ->
          if Enum.all?(list, &is_map/1),
            do: [],
            else: ["#{key}: every entry must be a JSON object"]

        _ ->
          ["#{key} must be a list"]
      end
    end)
  end

  def export_bundle(company_id, %Date{} = date) do
    %{
      "bundle_version" => @bundle_version,
      "source" => "export",
      "rate_tables" => export_kind(company_id, date, :table),
      "calcs" => export_kind(company_id, date, :calc),
      "file_formats" => export_kind(company_id, date, :file_format)
    }
  end

  def import_bundle(bundle, company, user) do
    if FullCircle.Authorization.can?(user, :manage_statutory_config, company) do
      case validate_bundle(bundle) do
        :ok ->
          time = DateTime.truncate(DateTime.utc_now(), :second)

          multi =
            Multi.new()
            |> import_bundle_kind(
              bundle["rate_tables"] || [],
              company.id,
              time,
              StatutoryRateTable
            )
            |> import_bundle_kind(bundle["calcs"] || [], company.id, time, StatutoryCalc)
            |> import_bundle_kind(
              bundle["file_formats"] || [],
              company.id,
              time,
              StatutoryFileFormat
            )

          case Repo.transaction(multi) do
            {:ok, results} ->
              Cache.invalidate(company.id)
              {:ok, import_counts(results)}

            {:error, _op, reason, _} ->
              {:error, [Exception.message(reason)]}
          end

        {:error, errors} ->
          {:error, errors}
      end
    else
      :not_authorise
    end
  end

  def seed_company!(company_id) do
    bundle = template_bundle()
    time = DateTime.truncate(DateTime.utc_now(), :second)

    seed_kind(bundle["rate_tables"] || [], company_id, time, StatutoryRateTable)
    seed_kind(bundle["calcs"] || [], company_id, time, StatutoryCalc)
    seed_kind(bundle["file_formats"] || [], company_id, time, StatutoryFileFormat)

    Cache.invalidate(company_id)
    :ok
  end

  def preview_calc(script, code, emp, month, year) do
    cs = preview_changeset(emp, month, year)
    eval_script(script, code, emp, month, year, cs)
  end

  def current_value(code, emp, month, year) do
    date = Timex.end_of_month(year, month)

    case effective_calc(emp.company_id, code, date) do
      nil ->
        nil

      %{script: script} ->
        case preview_calc(script, code, emp, month, year) do
          {:ok, dec} -> dec
          _ -> nil
        end
    end
  end

  def parse_table_csv(binary) when is_binary(binary) do
    lines =
      binary
      |> String.trim()
      |> String.split(~r/\r?\n/, trim: true)

    case lines do
      [] ->
        {:error, "CSV must have a header row"}

      [header | data_lines] ->
        cond do
          String.contains?(header, "\"") ->
            {:error, "quoted CSV is not supported"}

          true ->
            columns = header |> String.split(",") |> Enum.map(&String.trim/1)

            case parse_csv_rows(data_lines, columns, 2) do
              {:ok, rows} -> {:ok, %{columns: columns, rows: rows}}
              {:error, msg} -> {:error, msg}
            end
        end
    end
  end

  def bundle_diff(bundle, company_id) when is_map(bundle) do
    kinds = [
      {:table, bundle["rate_tables"] || []},
      {:calc, bundle["calcs"] || []},
      {:file_format, bundle["file_formats"] || []}
    ]

    Enum.flat_map(kinds, fn {kind, entries} ->
      Enum.map(entries, fn entry ->
        code = entry["code"]
        effective_from = parse_bundle_date!(entry["effective_from"])
        existing = find_version(kind, company_id, code, effective_from)

        status =
          cond do
            is_nil(existing) -> :new
            bundle_entry_same?(kind, entry, existing) -> :unchanged
            true -> :replaces
          end

        %{kind: kind, code: code, effective_from: effective_from, status: status}
      end)
    end)
  end

  @doc """
  Computes calc `code` for the changeset's pay period.

  Returns `{:ok, Decimal}` | `{:error, PayScript.Error}`, or:
  - `:not_found` — the company has no version of this code at all
    (caller may fall back to the legacy module);
  - `:not_effective` — versions exist but none is effective for the pay
    period, so the registry owns the code and the amount is zero.
  """
  def calculate(code, emp, cs) do
    pay_month = fetch_field!(cs, :pay_month)
    pay_year = fetch_field!(cs, :pay_year)
    date = Timex.end_of_month(pay_year, pay_month)

    case versions(:calc, emp.company_id, code) do
      [] ->
        :not_found

      vs ->
        case Enum.find(vs, fn v -> Date.compare(v.effective_from, date) != :gt end) do
          nil -> :not_effective
          version -> run_calc(version.script, emp, cs, date, pay_month, pay_year)
        end
    end
  end

  defp run_calc(script, emp, cs, date, pay_month, pay_year) do
    context = script_context(emp, cs)

    state = %{
      company_id: emp.company_id,
      date: date,
      context: context,
      employee_id: emp.id,
      pay_month: pay_month,
      pay_year: pay_year
    }

    case PayScript.eval(script, context, {DbEnv, state}) do
      {:ok, dec} -> {:ok, dec}
      {:error, %Error{} = e} -> {:error, e}
    end
  end

  defp validate_bundle_version(errors, %{"bundle_version" => @bundle_version}), do: errors

  defp validate_bundle_version(errors, _bundle),
    do: ["bundle_version must be #{@bundle_version}" | errors]

  defp validate_bundle_entries(errors, bundle) do
    dummy_id = Ecto.UUID.generate()

    Enum.reduce(
      [
        {"rate_tables", StatutoryRateTable, &table_bundle_attrs/2},
        {"calcs", StatutoryCalc, &calc_bundle_attrs/2},
        {"file_formats", StatutoryFileFormat, &file_format_bundle_attrs/2}
      ],
      errors,
      fn {key, schema, to_attrs}, acc ->
        (bundle[key] || [])
        |> Enum.reduce(acc, fn entry, entry_errors ->
          entry_errors ++
            bundle_date_errors(key, entry) ++
            changeset_errors(schema.changeset(struct(schema), to_attrs.(entry, dummy_id)))
        end)
      end
    )
  end

  defp bundle_date_errors(key, entry) do
    case entry["effective_from"] do
      nil -> []
      v -> if parse_bundle_date(v), do: [], else: ["#{key}: invalid effective_from #{inspect(v)}"]
    end
  end

  # Entries missing keys or with bad dates are already reported by
  # validate_bundle_entries; skip them here instead of crashing.
  defp validate_bundle_calcs(errors, bundle) do
    calcs =
      for %{"code" => code, "script" => script} = entry <- bundle["calcs"] || [],
          is_binary(code) and is_binary(script),
          do: entry

    tables =
      (bundle["rate_tables"] || [])
      |> Enum.filter(&(is_binary(&1["code"]) and is_list(&1["columns"])))
      |> Enum.group_by(& &1["code"])
      |> Map.new(fn {code, entries} ->
        entry = Enum.max_by(entries, &bundle_entry_date/1, Date)
        {code, entry["columns"]}
      end)

    codes = Enum.map(calcs, & &1["code"])

    calc_errors =
      Enum.flat_map(calcs, fn %{"script" => script, "code" => code} ->
        schema = %{tables: tables, calcs: codes}

        case PayScript.validate(script, schema) do
          :ok -> []
          {:error, errs} -> Enum.map(errs, &"calc '#{code}': #{Exception.message(&1)}")
        end
      end)

    sources =
      calcs
      |> Enum.group_by(& &1["code"])
      |> Map.new(fn {code, entries} ->
        entry = Enum.max_by(entries, &bundle_entry_date/1, Date)
        {code, entry["script"]}
      end)

    cycle_errors =
      case PayScript.check_cycles(sources) do
        :ok -> []
        {:error, err} -> [Exception.message(err)]
      end

    calc_errors ++ cycle_errors ++ errors
  end

  defp changeset_errors(%Ecto.Changeset{valid?: true}), do: []

  defp changeset_errors(cs) do
    cs
    |> errors_on()
    |> Enum.flat_map(fn {field, msgs} ->
      Enum.map(msgs, fn msg -> "#{field}: #{msg}" end)
    end)
  end

  defp errors_on(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp export_kind(company_id, date, kind) do
    schema = @kinds[kind]

    from(r in schema, where: r.company_id == ^company_id, distinct: r.code, select: r.code)
    |> Repo.all()
    |> Enum.map(&effective(kind, company_id, &1, date))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&export_entry(kind, &1))
  end

  defp export_entry(:table, t) do
    %{
      "code" => t.code,
      "effective_from" => Date.to_iso8601(t.effective_from),
      "columns" => t.columns,
      "rows" => t.rows
    }
  end

  defp export_entry(:calc, c) do
    %{
      "code" => c.code,
      "name" => c.name,
      "effective_from" => Date.to_iso8601(c.effective_from),
      "script" => c.script
    }
  end

  defp export_entry(:file_format, f) do
    %{
      "code" => f.code,
      "name" => f.name,
      "effective_from" => Date.to_iso8601(f.effective_from),
      "renderer" => f.renderer,
      "spec" => f.spec
    }
  end

  defp import_bundle_kind(multi, entries, company_id, time, schema) do
    rows = bundle_rows_list(entries, company_id, time, schema)

    if rows == [] do
      multi
    else
      Multi.insert_all(multi, import_op_name(schema), schema, rows,
        on_conflict: {:replace_all_except, [:id, :inserted_at]},
        conflict_target: [:company_id, :code, :effective_from]
      )
    end
  end

  defp import_op_name(StatutoryRateTable), do: :import_rate_tables
  defp import_op_name(StatutoryCalc), do: :import_calcs
  defp import_op_name(StatutoryFileFormat), do: :import_file_formats

  defp import_counts(results) do
    %{
      rate_tables: import_count(results, :import_rate_tables),
      calcs: import_count(results, :import_calcs),
      file_formats: import_count(results, :import_file_formats)
    }
  end

  defp import_count(results, key) do
    case Map.get(results, key) do
      {n, _} -> n
      _ -> 0
    end
  end

  defp seed_kind(entries, company_id, time, schema) do
    rows = bundle_rows_list(entries, company_id, time, schema)

    if rows != [] do
      Repo.insert_all(schema, rows,
        on_conflict: :nothing,
        conflict_target: [:company_id, :code, :effective_from]
      )
    end

    :ok
  end

  defp bundle_rows_list(entries, company_id, time, schema) do
    Enum.map(entries, fn entry ->
      entry
      |> row_from_bundle(company_id, time, schema)
      |> Map.put(:id, Ecto.UUID.generate())
    end)
  end

  defp row_from_bundle(entry, company_id, time, StatutoryRateTable) do
    %{
      company_id: company_id,
      code: entry["code"],
      effective_from: parse_bundle_date!(entry["effective_from"]),
      columns: entry["columns"],
      rows: entry["rows"],
      inserted_at: time,
      updated_at: time
    }
  end

  defp row_from_bundle(entry, company_id, time, StatutoryCalc) do
    %{
      company_id: company_id,
      code: entry["code"],
      name: entry["name"],
      effective_from: parse_bundle_date!(entry["effective_from"]),
      script: entry["script"],
      inserted_at: time,
      updated_at: time
    }
  end

  defp row_from_bundle(entry, company_id, time, StatutoryFileFormat) do
    %{
      company_id: company_id,
      code: entry["code"],
      name: entry["name"],
      effective_from: parse_bundle_date!(entry["effective_from"]),
      renderer: entry["renderer"] || "text",
      spec: entry["spec"] || %{},
      inserted_at: time,
      updated_at: time
    }
  end

  defp table_bundle_attrs(entry, company_id) do
    %{
      code: entry["code"],
      effective_from: parse_bundle_date(entry["effective_from"]),
      columns: entry["columns"],
      rows: entry["rows"],
      company_id: company_id
    }
  end

  defp calc_bundle_attrs(entry, company_id) do
    %{
      code: entry["code"],
      name: entry["name"],
      effective_from: parse_bundle_date(entry["effective_from"]),
      script: entry["script"],
      company_id: company_id
    }
  end

  defp file_format_bundle_attrs(entry, company_id) do
    %{
      code: entry["code"],
      name: entry["name"],
      effective_from: parse_bundle_date(entry["effective_from"]),
      renderer: entry["renderer"] || "text",
      spec: entry["spec"] || %{},
      company_id: company_id
    }
  end

  # Tolerant variant for pre-import validation: nil instead of raise.
  defp parse_bundle_date(iso) when is_binary(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  defp parse_bundle_date(%Date{} = date), do: date
  defp parse_bundle_date(_), do: nil

  defp bundle_entry_date(entry),
    do: parse_bundle_date(entry["effective_from"]) || ~D[0001-01-01]

  defp parse_bundle_date!(iso) when is_binary(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> date
      {:error, reason} -> raise "invalid effective_from #{inspect(iso)}: #{inspect(reason)}"
    end
  end

  defp parse_bundle_date!(%Date{} = date), do: date

  defp sanitize_log_attrs(attrs) do
    attrs
    |> Map.new(fn {k, v} ->
      val =
        cond do
          is_list(v) and v != [] and is_list(hd(v)) -> Jason.encode!(v)
          is_map(v) -> Jason.encode!(v)
          true -> v
        end

      {k, val}
    end)
  end

  defp add_placeholder_calcs(sources, refs) do
    Enum.reduce(refs, sources, fn dep, acc ->
      if Map.has_key?(acc, dep), do: acc, else: Map.put(acc, dep, "result = 0")
    end)
  end

  defp preview_changeset(emp, month, year) do
    addition_sum =
      emp.id
      |> FullCircle.HR.get_employee_salary_types()
      |> Enum.filter(&(&1.type == "Addition"))
      |> Enum.map(& &1.amount)
      |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

    %PaySlip{}
    |> change(%{
      pay_month: month,
      pay_year: year,
      addition_amount: addition_sum,
      bonus_amount: Decimal.new(0)
    })
  end

  defp eval_script(script, _code, emp, month, year, cs) do
    date = Timex.end_of_month(year, month)
    context = script_context(emp, cs)

    state = %{
      company_id: emp.company_id,
      date: date,
      context: context,
      employee_id: emp.id,
      pay_month: month,
      pay_year: year
    }

    case PayScript.eval(script, context, {DbEnv, state}) do
      {:ok, dec} -> {:ok, dec}
      {:error, %Error{} = e} -> {:error, Exception.message(e)}
    end
  end

  defp parse_csv_rows(lines, columns, line_no) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      cond do
        String.contains?(line, "\"") ->
          {:halt, {:error, "line #{line_no}: quoted CSV is not supported"}}

        true ->
          cells = line |> String.split(",") |> Enum.map(&String.trim/1)

          cond do
            length(cells) != length(columns) ->
              {:halt, {:error, "line #{line_no}: expected #{length(columns)} columns"}}

            true ->
              case parse_csv_cells(cells, line_no) do
                {:ok, floats} -> {:cont, {:ok, acc ++ [floats]}}
                {:error, msg} -> {:halt, {:error, msg}}
              end
          end
      end
    end)
    |> case do
      {:ok, []} -> {:error, "CSV must have at least one data row"}
      other -> other
    end
  end

  defp parse_csv_cells(cells, line_no) do
    Enum.reduce_while(cells, {:ok, []}, fn cell, {:ok, acc} ->
      case Float.parse(cell) do
        {n, ""} -> {:cont, {:ok, acc ++ [n]}}
        _ -> {:halt, {:error, "line #{line_no}: invalid number #{inspect(cell)}"}}
      end
    end)
  end

  defp find_version(kind, company_id, code, effective_from) do
    schema = @kinds[kind]

    from(r in schema,
      where:
        r.company_id == ^company_id and r.code == ^code and
          r.effective_from == ^effective_from
    )
    |> Repo.one()
  end

  defp bundle_entry_same?(:table, entry, existing) do
    entry["columns"] == existing.columns and entry["rows"] == existing.rows
  end

  defp bundle_entry_same?(:calc, entry, existing) do
    entry["name"] == existing.name and entry["script"] == existing.script
  end

  defp bundle_entry_same?(:file_format, entry, existing) do
    (entry["name"] || "") == existing.name and
      (entry["renderer"] || "text") == existing.renderer and
      (entry["spec"] || %{}) == existing.spec
  end

  defp save(cs, company, user, action, log_attrs) do
    if FullCircle.Authorization.can?(user, :manage_statutory_config, company) do
      Multi.new()
      |> Multi.insert_or_update(String.to_atom(action), cs)
      |> Sys.insert_log_for(String.to_atom(action), sanitize_log_attrs(log_attrs), company, user)
      |> Repo.transaction()
      |> case do
        {:ok, result} ->
          Cache.invalidate(company.id)
          {:ok, Map.fetch!(result, String.to_atom(action))}

        {:error, _op, failed_cs, _} ->
          {:error, failed_cs}
      end
    else
      :not_authorise
    end
  end
end
