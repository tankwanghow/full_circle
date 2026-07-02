defmodule FullCircle.StatutoryConfig.BundleTest do
  use FullCircle.DataCase, async: false

  alias FullCircle.StatutoryConfig
  alias FullCircle.HR.{StatutoryCalc, StatutoryRateTable}
  alias FullCircle.Repo

  import Ecto.Query
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  @template_codes ~w(
    epf_relief_cap pcb_individual_deduction pcb_spouse_deduction pcb_child_deduction
    epf_employer epf_employee socso_employer socso_employee socso_employer_only socso_24hour
    eis_employer eis_employee eis_employer_only pcb_employee
  )

  setup do
    admin = user_fixture()
    com = company_fixture(admin, %{})
    %{com: com, user: admin}
  end

  test "template bundle validates offline" do
    assert :ok = StatutoryConfig.validate_bundle(StatutoryConfig.template_bundle())
  end

  test "import then export round-trips every code", %{com: com, user: user} do
    bundle = StatutoryConfig.template_bundle()
    assert {:ok, _} = StatutoryConfig.import_bundle(bundle, com, user)

    exported = StatutoryConfig.export_bundle(com.id, ~D[2026-06-30])

    for kind <- ["rate_tables", "calcs"] do
      imported_codes = bundle[kind] |> Enum.map(& &1["code"]) |> Enum.sort()
      exported_codes = exported[kind] |> Enum.map(& &1["code"]) |> Enum.sort()
      assert imported_codes == exported_codes
    end
  end

  test "validate_bundle catches bad script, unknown table ref, cycle, malformed row" do
    base = StatutoryConfig.template_bundle()

    bad_script =
      update_in(base, ["calcs", Access.at(4), "script"], fn _ ->
        "result = lookup(\"ghost\", wages, \"employee\")"
      end)

    assert {:error, errors} = StatutoryConfig.validate_bundle(bad_script)
    assert Enum.any?(errors, &(&1 =~ "ghost"))

    cycled =
      update_in(base, ["calcs"], fn calcs ->
        calcs ++
          [
            %{
              "code" => "cycle_a",
              "name" => "A",
              "effective_from" => "2026-01-01",
              "script" => ~s|result = calc("cycle_b")|
            },
            %{
              "code" => "cycle_b",
              "name" => "B",
              "effective_from" => "2026-01-01",
              "script" => ~s|result = calc("cycle_a")|
            }
          ]
      end)

    assert {:error, cycle_errors} = StatutoryConfig.validate_bundle(cycled)
    assert Enum.any?(cycle_errors, &(&1 =~ "cycle"))

    bad_rows =
      update_in(base, ["rate_tables", Access.at(0), "rows"], fn rows ->
        [[0.0, 30.0, 0.1] | rows]
      end)

    assert {:error, row_errors} = StatutoryConfig.validate_bundle(bad_rows)
    assert Enum.any?(row_errors, &(&1 =~ "rows"))

    assert {:error, script_errors} =
             StatutoryConfig.validate_bundle(%{
               base
               | "calcs" => [
                   %{
                     "code" => "x",
                     "name" => "X",
                     "effective_from" => "2026-01-01",
                     "script" => "a = wage_typo\nresult = a"
                   }
                 ]
             })

    assert Enum.any?(script_errors, &(&1 =~ "script"))
  end

  test "import rejects invalid bundles", %{com: com, user: user} do
    invalid = %{"bundle_version" => 99, "rate_tables" => [], "calcs" => [], "file_formats" => []}
    assert {:error, _} = StatutoryConfig.import_bundle(invalid, com, user)
  end

  test "re-import is idempotent via upsert", %{com: com, user: user} do
    bundle = StatutoryConfig.template_bundle()

    assert {:ok, counts1} = StatutoryConfig.import_bundle(bundle, com, user)
    assert {:ok, counts2} = StatutoryConfig.import_bundle(bundle, com, user)

    assert counts1.rate_tables > 0
    assert counts1.calcs > 0
    assert counts2.rate_tables == counts1.rate_tables
    assert counts2.calcs == counts1.calcs
  end

  test "mix statutory.validate green and red paths" do
    path = Path.join(System.tmp_dir!(), "bundle-#{System.unique_integer()}.json")
    File.write!(path, Jason.encode!(StatutoryConfig.template_bundle()))

    assert ExUnit.CaptureIO.capture_io(fn ->
             Mix.Task.rerun("statutory.validate", [path])
           end) =~ "bundle OK"

    File.write!(path, Jason.encode!(%{"bundle_version" => 99}))

    assert_raise Mix.Error, fn ->
      Mix.Task.rerun("statutory.validate", [path])
    end
  end

  test "validate_bundle rejects malformed bundles without raising" do
    assert {:error, ["bundle must be a JSON object"]} = StatutoryConfig.validate_bundle([])

    assert {:error, errors} =
             StatutoryConfig.validate_bundle(%{"bundle_version" => 1, "calcs" => %{}})

    assert Enum.any?(errors, &(&1 =~ "must be a list"))

    assert {:error, errors} =
             StatutoryConfig.validate_bundle(%{"bundle_version" => 1, "calcs" => ["oops"]})

    assert Enum.any?(errors, &(&1 =~ "JSON object"))

    bad_date = %{
      "bundle_version" => 1,
      "calcs" => [
        %{"code" => "a", "name" => "A", "effective_from" => "junk", "script" => "result = 1"}
      ]
    }

    assert {:error, errors} = StatutoryConfig.validate_bundle(bad_date)
    assert Enum.any?(errors, &(&1 =~ "invalid effective_from"))

    missing_script = %{
      "bundle_version" => 1,
      "calcs" => [%{"code" => "a", "name" => "A", "effective_from" => "2026-01-01"}]
    }

    assert {:error, errors} = StatutoryConfig.validate_bundle(missing_script)
    assert Enum.any?(errors, &(&1 =~ "script"))
  end

  describe "seed_company!" do
    test "seeds all template calc codes and is idempotent", %{com: com} do
      StatutoryConfig.seed_company!(com.id)

      codes = StatutoryConfig.calc_codes(com.id) |> Enum.sort()
      assert codes == Enum.sort(@template_codes)

      table_count =
        from(t in StatutoryRateTable, where: t.company_id == ^com.id) |> Repo.aggregate(:count)

      calc_count = from(c in StatutoryCalc, where: c.company_id == ^com.id) |> Repo.aggregate(:count)

      StatutoryConfig.seed_company!(com.id)

      assert table_count ==
               from(t in StatutoryRateTable, where: t.company_id == ^com.id) |> Repo.aggregate(:count)

      assert calc_count ==
               from(c in StatutoryCalc, where: c.company_id == ^com.id) |> Repo.aggregate(:count)
    end

    test "create_company leaves company with template calc codes" do
      admin = user_fixture()
      com = company_fixture(admin, %{})
      codes = StatutoryConfig.calc_codes(com.id) |> Enum.sort()
      assert codes == Enum.sort(@template_codes)
    end
  end
end