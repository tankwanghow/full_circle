defmodule FullCircle.StatutoryConfigTest do
  use FullCircle.DataCase, async: false

  alias FullCircle.StatutoryConfig
  alias FullCircle.HR.{StatutoryCalc, StatutoryRateTable, StatutoryFileFormat}

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  @com_id Ecto.UUID.generate()

  defp table_attrs(over \\ %{}) do
    Map.merge(
      %{
        code: "socso",
        effective_from: ~D[1957-01-01],
        columns: ["wage_from", "wage_to", "employee"],
        rows: [[0.0, 30.0, 0.1], [30.0, 50.0, 0.2]],
        company_id: @com_id
      },
      over
    )
  end

  test "valid rate table changeset" do
    assert %{valid?: true} = StatutoryRateTable.changeset(%StatutoryRateTable{}, table_attrs())
  end

  test "code format is enforced on all three schemas" do
    for {mod, attrs} <- [
          {StatutoryRateTable, table_attrs(%{code: "Bad Code"})},
          {StatutoryCalc,
           %{
             code: "Bad Code",
             name: "x",
             effective_from: ~D[2026-01-01],
             script: "result = 1",
             company_id: @com_id
           }},
          {StatutoryFileFormat,
           %{
             code: "Bad Code",
             name: "x",
             effective_from: ~D[2026-01-01],
             renderer: "text",
             spec: %{},
             company_id: @com_id
           }}
        ] do
      cs = mod.changeset(struct(mod), attrs)
      assert %{code: [_ | _]} = errors_on(cs)
    end
  end

  test "rate table rejects row width mismatch, non-contiguous and inverted brackets" do
    assert %{rows: [_ | _]} =
             errors_on(StatutoryRateTable.changeset(%StatutoryRateTable{}, table_attrs(%{rows: [[0.0, 30.0]]})))

    assert %{rows: [msg | _]} =
             errors_on(
               StatutoryRateTable.changeset(
                 %StatutoryRateTable{},
                 table_attrs(%{rows: [[0.0, 30.0, 0.1], [40.0, 50.0, 0.2]]})
               )
             )

    assert msg =~ "contiguous"

    assert %{rows: [_ | _]} =
             errors_on(StatutoryRateTable.changeset(%StatutoryRateTable{}, table_attrs(%{rows: [[30.0, 0.0, 0.1]]})))
  end

  test "calc script must parse and validate" do
    cs =
      StatutoryCalc.changeset(%StatutoryCalc{}, %{
        code: "x",
        name: "X",
        effective_from: ~D[2026-01-01],
        script: "a = wage_typo\nresult = a",
        company_id: @com_id
      })

    assert %{script: [msg | _]} = errors_on(cs)
    assert msg =~ "unknown identifier 'wage_typo'"
  end

  test "file format renderer restricted to text" do
    cs =
      StatutoryFileFormat.changeset(%StatutoryFileFormat{}, %{
        code: "epf_form_a",
        name: "EPF",
        effective_from: ~D[2026-01-01],
        renderer: "xlsx",
        spec: %{},
        company_id: @com_id
      })

    assert %{renderer: [_ | _]} = errors_on(cs)
  end

  describe "preview_calc/5 and current_value/4" do
    setup do
      admin = user_fixture()
      com = company_fixture(admin, %{})
      StatutoryConfig.seed_company!(com.id)
      emp = FullCircle.HRFixtures.employee_fixture(%{}, com, admin)
      %{com: com, user: admin, emp: emp}
    end

    test "preview matches calculate/3 for seeded calc", %{com: com, user: user, emp: emp} do
      monthly = FullCircle.HR.get_salary_type_by_name("Monthly Salary", com, user)

      {:ok, _} =
        FullCircle.Repo.insert(%FullCircle.HR.EmployeeSalaryType{
          employee_id: emp.id,
          salary_type_id: monthly.id,
          amount: Decimal.new("3000")
        })

      cs =
        %FullCircle.HR.PaySlip{}
        |> Ecto.Changeset.change(%{
          pay_month: 6,
          pay_year: 2026,
          addition_amount: Decimal.new("3000"),
          bonus_amount: Decimal.new(0)
        })

      %{script: script} = StatutoryConfig.effective_calc(com.id, "epf_employee", ~D[2026-06-30])
      {:ok, calc_val} = StatutoryConfig.calculate("epf_employee", emp, cs)
      {:ok, preview_val} = StatutoryConfig.preview_calc(script, "epf_employee", emp, 6, 2026)

      assert Decimal.equal?(calc_val, preview_val)
    end

    test "preview of edited source differs from current_value", %{emp: emp} do
      {:ok, edited} = StatutoryConfig.preview_calc("result = 99", "epf_employee", emp, 6, 2026)
      current = StatutoryConfig.current_value("epf_employee", emp, 6, 2026)

      assert Decimal.equal?(edited, Decimal.new(99))
      refute Decimal.equal?(edited, current)
    end

    test "current_value is nil when no calc exists", %{emp: emp} do
      assert is_nil(StatutoryConfig.current_value("ghost_calc", emp, 6, 2026))
    end
  end

  describe "parse_table_csv/1" do
    test "happy path" do
      csv = """
      wage_from,wage_to,employee
      0,30,0.1
      30,50,0.2
      """

      assert {:ok, %{columns: ["wage_from", "wage_to", "employee"], rows: rows}} =
               StatutoryConfig.parse_table_csv(csv)

      assert rows == [[0.0, 30.0, 0.1], [30.0, 50.0, 0.2]]
    end

    test "bad number names line" do
      csv = """
      wage_from,wage_to,employee
      0,30,0.1
      30,50,0.2
      bad,60,0.3
      """

      assert {:error, msg} = StatutoryConfig.parse_table_csv(csv)
      assert msg =~ "invalid number"
      assert msg =~ "bad"
    end

    test "short row" do
      csv = """
      wage_from,wage_to,employee
      0,30
      """

      assert {:error, msg} = StatutoryConfig.parse_table_csv(csv)
      assert msg =~ "line 2"
    end
  end

  describe "bundle_diff/2" do
    setup do
      admin = user_fixture()
      com = company_fixture(admin, %{})
      StatutoryConfig.seed_company!(com.id)
      %{com: com, bundle: StatutoryConfig.template_bundle()}
    end

    test "template against seeded company is all unchanged", %{com: com, bundle: bundle} do
      diff = StatutoryConfig.bundle_diff(bundle, com.id)
      assert diff != []
      assert Enum.all?(diff, &(&1.status == :unchanged))
    end

    test "bumped script is replaces", %{com: com, bundle: bundle} do
      bumped =
        put_in(
          bundle,
          ["calcs"],
          Enum.map(bundle["calcs"], fn
            %{"code" => "epf_employee"} = c -> Map.put(c, "script", "result = 1")
            c -> c
          end)
        )

      row = Enum.find(StatutoryConfig.bundle_diff(bumped, com.id), &(&1.code == "epf_employee"))
      assert row.status == :replaces
    end

    test "new code is new", %{com: com, bundle: bundle} do
      extra =
        Map.update!(bundle, "calcs", fn calcs ->
          calcs ++
            [
              %{
                "code" => "hrdf_levy",
                "name" => "HRDF",
                "effective_from" => "2026-01-01",
                "script" => "result = 1"
              }
            ]
        end)

      row = Enum.find(StatutoryConfig.bundle_diff(extra, com.id), &(&1.code == "hrdf_levy"))
      assert row.status == :new
    end
  end

  describe "save/resolution" do
    setup do
      admin = user_fixture()
      com = company_fixture(admin, %{})
      %{com: com, user: admin}
    end

    test "save_calc persists and effective_calc resolves by date", %{com: com, user: user} do
      {:ok, _v1} =
        StatutoryConfig.save_calc(
          %{code: "versioned_calc", name: "Versioned", effective_from: ~D[2026-06-01], script: "result = 1"},
          com,
          user
        )

      {:ok, _v2} =
        StatutoryConfig.save_calc(
          %{code: "versioned_calc", name: "Versioned", effective_from: ~D[2027-01-01], script: "result = 2"},
          com,
          user
        )

      assert StatutoryConfig.effective_calc(com.id, "versioned_calc", ~D[2026-05-31]) == nil
      assert %{script: "result = 1"} = StatutoryConfig.effective_calc(com.id, "versioned_calc", ~D[2026-06-30])
      assert %{script: "result = 2"} = StatutoryConfig.effective_calc(com.id, "versioned_calc", ~D[2027-03-31])
    end

    test "save_calc replace: true corrects a version in place", %{com: com, user: user} do
      attrs = %{code: "fix_me", name: "Fix", effective_from: ~D[2026-06-01], script: "result = 1"}
      {:ok, v1} = StatutoryConfig.save_calc(attrs, com, user)

      # without replace, the same effective date is rejected
      assert {:error, cs} = StatutoryConfig.save_calc(%{attrs | script: "result = 2"}, com, user)
      refute cs.valid?

      assert StatutoryConfig.version_exists?(:calc, com.id, "fix_me", ~D[2026-06-01])
      assert StatutoryConfig.version_exists?(:calc, com.id, "fix_me", "2026-06-01")
      refute StatutoryConfig.version_exists?(:calc, com.id, "fix_me", ~D[2026-07-01])

      {:ok, v2} =
        StatutoryConfig.save_calc(%{attrs | script: "result = 2"}, com, user, replace: true)

      # same row updated, not a new version
      assert v2.id == v1.id
      assert %{script: "result = 2"} = StatutoryConfig.effective_calc(com.id, "fix_me", ~D[2026-06-30])

      assert [_only_one] =
               StatutoryConfig.list_versions(:calc, com.id) |> Enum.filter(&(&1.code == "fix_me"))
    end

    test "save_calc rejects unknown table reference and calc cycles", %{com: com, user: user} do
      assert {:error, cs} =
               StatutoryConfig.save_calc(
                 %{
                   code: "a",
                   name: "A",
                   effective_from: ~D[2026-01-01],
                   script: ~s|result = lookup("ghost", wages, "employee")|
                 },
                 com,
                 user
               )

      assert %{script: [msg | _]} = errors_on(cs)
      assert msg =~ "unknown table 'ghost'"

      {:ok, _} =
        StatutoryConfig.save_calc(
          %{code: "b", name: "B", effective_from: ~D[2026-01-01], script: ~s|result = calc("c")|},
          com,
          user
        )

      assert {:error, cs} =
               StatutoryConfig.save_calc(
                 %{code: "c", name: "C", effective_from: ~D[2026-01-01], script: ~s|result = calc("b")|},
                 com,
                 user
               )

      assert %{script: [msg | _]} = errors_on(cs)
      assert msg =~ "cycle"
    end

    test "non-admin cannot save", %{com: com, user: admin} do
      clerk = user_fixture()
      {:ok, _} = FullCircle.Sys.allow_user_to_access(com, clerk, "clerk", admin)

      assert :not_authorise =
               StatutoryConfig.save_calc(
                 %{code: "x", name: "X", effective_from: ~D[2026-01-01], script: "result = 1"},
                 com,
                 clerk
               )
    end

    test "cache is invalidated on save", %{com: com, user: user} do
      {:ok, _} =
        StatutoryConfig.save_calc(
          %{code: "x", name: "X", effective_from: ~D[2026-01-01], script: "result = 1"},
          com,
          user
        )

      assert %{script: "result = 1"} = StatutoryConfig.effective_calc(com.id, "x", ~D[2026-06-30])

      {:ok, _} =
        StatutoryConfig.save_calc(
          %{code: "x", name: "X", effective_from: ~D[2026-03-01], script: "result = 9"},
          com,
          user
        )

      assert %{script: "result = 9"} = StatutoryConfig.effective_calc(com.id, "x", ~D[2026-06-30])
    end
  end
end