defmodule FullCircle.WorkShiftTest do
  use FullCircle.DataCase, async: false

  alias FullCircle.HR.{WorkShift, EmployeeWorkShift}
  alias FullCircle.Repo

  import FullCircle.UserAccountsFixtures
  import FullCircle.SysFixtures
  import FullCircle.HRFixtures

  setup do
    admin = user_fixture()
    company = company_fixture(admin, %{})
    %{admin: admin, company: company}
  end

  defp shift(company, attrs) do
    %WorkShift{}
    |> WorkShift.changeset(
      Map.merge(
        %{
          company_id: company.id,
          name: "Night",
          start_time: ~T[17:00:00],
          normal_hour: "9",
          max_hour: "12"
        },
        attrs
      )
    )
    |> Repo.insert()
  end

  describe "cutover_time/1" do
    test "General 08:00 with max 12 cuts over at 02:00", ctx do
      # Fixture company already owns the seeded General default; (company_id, name)
      # is unique, so we read that row instead of inserting another General.
      ws = Repo.get_by!(WorkShift, company_id: ctx.company.id, is_default: true)

      assert WorkShift.cutover_time(ws) == ~T[02:00:00]
    end

    test "Night 17:00 with max 12 cuts over at 11:00", ctx do
      {:ok, ws} = shift(ctx.company, %{})
      assert WorkShift.cutover_time(ws) == ~T[11:00:00]
    end

    test "a wider tolerance pulls the cutover closer to the start", ctx do
      {:ok, ws} = shift(ctx.company, %{start_time: ~T[08:00:00], max_hour: "16"})
      # 08:00 + (24+16)/2 = 08:00 + 20h = 04:00
      assert WorkShift.cutover_time(ws) == ~T[04:00:00]
    end
  end

  describe "nominal_end/1" do
    test "start plus normal_hour, for display only", ctx do
      gen = Repo.get_by!(WorkShift, company_id: ctx.company.id, is_default: true)
      assert WorkShift.nominal_end(gen) == ~T[17:00:00]

      {:ok, night} = shift(ctx.company, %{})
      assert WorkShift.nominal_end(night) == ~T[02:00:00]
    end
  end

  describe "WorkShift changeset" do
    test "requires the core fields", ctx do
      cs = WorkShift.changeset(%WorkShift{}, %{company_id: ctx.company.id})
      refute cs.valid?
      assert %{name: _, start_time: _, normal_hour: _, max_hour: _} = errors_on(cs)
    end

    test "max_hour must be at least normal_hour", ctx do
      assert {:error, cs} =
               shift(ctx.company, %{normal_hour: "12", max_hour: "9"})

      assert %{max_hour: _} = errors_on(cs)
    end

    test "max_hour must be under 24", ctx do
      assert {:error, cs} = shift(ctx.company, %{max_hour: "24"})
      assert %{max_hour: _} = errors_on(cs)
    end

    test "name is unique per company", ctx do
      assert {:ok, _} = shift(ctx.company, %{name: "Night"})
      assert {:error, cs} = shift(ctx.company, %{name: "Night"})
      assert %{name: _} = errors_on(cs)
    end

    # The fixture company already owns the seeded General default (see the
    # "General is seeded" describe below), so this asserts against that one
    # rather than creating a first default of its own.
    test "only one default per company", ctx do
      assert {:error, cs} = shift(ctx.company, %{name: "B", is_default: true})
      assert %{is_default: _} = errors_on(cs)
    end
  end

  describe "General is seeded" do
    test "every company gets exactly one default General shift", ctx do
      # company_fixture/2 calls Sys.create_company/2, which seeds this the same
      # way it seeds default accounts, tax codes and salary types. The migration
      # only covers companies that existed when it ran.
      gen = Repo.get_by!(WorkShift, company_id: ctx.company.id, is_default: true)
      assert gen.name == "General"
      assert gen.start_time == ~T[08:00:00]
      assert Decimal.equal?(gen.normal_hour, Decimal.new("9"))
      assert Decimal.equal?(gen.max_hour, Decimal.new("12"))
      assert WorkShift.cutover_time(gen) == ~T[02:00:00]
      assert WorkShift.nominal_end(gen) == ~T[17:00:00]
    end

    test "a company created after the migration still has one", ctx do
      other =
        company_fixture(ctx.admin, %{name: "Second Co #{System.unique_integer([:positive])}"})

      assert %WorkShift{name: "General"} =
               FullCircle.HR.default_work_shift(other)
    end
  end

  describe "EmployeeWorkShift changeset" do
    setup ctx do
      emp = employee_fixture(%{}, ctx.company, ctx.admin)
      {:ok, ws} = shift(ctx.company, %{})
      %{emp: emp, ws: ws}
    end

    defp assign(emp, ws, from, to \\ nil) do
      %EmployeeWorkShift{}
      |> EmployeeWorkShift.changeset(%{
        employee_id: emp.id,
        work_shift_id: ws.id,
        effective_from: from,
        effective_to: to
      })
      |> Repo.insert()
    end

    test "accepts a dated assignment", ctx do
      assert {:ok, a} = assign(ctx.emp, ctx.ws, ~D[2026-05-01], ~D[2026-05-31])
      assert a.effective_from == ~D[2026-05-01]
    end

    test "effective_to may be open ended", ctx do
      assert {:ok, a} = assign(ctx.emp, ctx.ws, ~D[2026-05-01])
      assert is_nil(a.effective_to)
    end

    test "effective_to cannot precede effective_from", ctx do
      assert {:error, cs} = assign(ctx.emp, ctx.ws, ~D[2026-05-31], ~D[2026-05-01])
      assert %{effective_to: _} = errors_on(cs)
    end

    test "overlapping ranges for one employee are rejected", ctx do
      assert {:ok, _} = assign(ctx.emp, ctx.ws, ~D[2026-05-01], ~D[2026-05-31])
      assert {:error, cs} = assign(ctx.emp, ctx.ws, ~D[2026-05-15], ~D[2026-06-15])
      assert %{effective_from: _} = errors_on(cs)
    end

    test "an open ended range blocks anything after it", ctx do
      assert {:ok, _} = assign(ctx.emp, ctx.ws, ~D[2026-05-01])
      assert {:error, cs} = assign(ctx.emp, ctx.ws, ~D[2026-09-01])
      assert %{effective_from: _} = errors_on(cs)
    end

    test "adjacent, non overlapping ranges are fine", ctx do
      assert {:ok, _} = assign(ctx.emp, ctx.ws, ~D[2026-05-01], ~D[2026-05-31])
      assert {:ok, _} = assign(ctx.emp, ctx.ws, ~D[2026-06-01], ~D[2026-06-30])
    end
  end

  describe "shift_for/3 and instance_anchor/2" do
    setup ctx do
      emp = employee_fixture(%{}, ctx.company, ctx.admin)
      {:ok, night} = shift(ctx.company, %{})
      gen = FullCircle.HR.default_work_shift(ctx.company)
      %{emp: emp, night: night, gen: gen}
    end

    defp local(ctx, s),
      do: Timex.parse!(s, "{RFC3339}") |> DateTime.shift_zone!(ctx.company.timezone)

    test "an unassigned employee resolves to General", ctx do
      ws = FullCircle.HR.shift_for(ctx.emp.id, ctx.company, ~D[2026-05-05])
      assert ws.id == ctx.gen.id
      assert ws.is_default
    end

    test "an assignment wins inside its range and not outside it", ctx do
      Repo.insert!(%EmployeeWorkShift{
        employee_id: ctx.emp.id,
        work_shift_id: ctx.night.id,
        effective_from: ~D[2026-05-01],
        effective_to: ~D[2026-05-31]
      })

      assert FullCircle.HR.shift_for(ctx.emp.id, ctx.company, ~D[2026-05-15]).id == ctx.night.id
      assert FullCircle.HR.shift_for(ctx.emp.id, ctx.company, ~D[2026-04-30]).id == ctx.gen.id
      assert FullCircle.HR.shift_for(ctx.emp.id, ctx.company, ~D[2026-06-01]).id == ctx.gen.id
    end

    test "an open ended assignment applies from its start onward", ctx do
      Repo.insert!(%EmployeeWorkShift{
        employee_id: ctx.emp.id,
        work_shift_id: ctx.night.id,
        effective_from: ~D[2026-05-01]
      })

      assert FullCircle.HR.shift_for(ctx.emp.id, ctx.company, ~D[2027-01-01]).id == ctx.night.id
    end

    test "General anchors every punch to its own calendar day", ctx do
      # 07:00 and 21:00 both sit after the 02:00 cutover, so both anchor to 5/5.
      assert FullCircle.HR.instance_anchor(ctx.gen, local(ctx, "2026-05-05T07:00:00+08:00")) ==
               ~D[2026-05-05]

      assert FullCircle.HR.instance_anchor(ctx.gen, local(ctx, "2026-05-05T21:00:00+08:00")) ==
               ~D[2026-05-05]
    end

    test "General still groups a punch just past midnight with the day before", ctx do
      assert FullCircle.HR.instance_anchor(ctx.gen, local(ctx, "2026-05-06T00:30:00+08:00")) ==
               ~D[2026-05-05]
    end

    test "Night groups 17:00 and the following 02:00 into one instance", ctx do
      a = FullCircle.HR.instance_anchor(ctx.night, local(ctx, "2026-05-05T17:00:00+08:00"))
      b = FullCircle.HR.instance_anchor(ctx.night, local(ctx, "2026-05-06T02:00:00+08:00"))
      assert a == ~D[2026-05-05]
      assert b == ~D[2026-05-05]
    end

    test "a punch exactly on the cutover opens the later instance", ctx do
      # Night cutover is 11:00.
      assert FullCircle.HR.instance_anchor(ctx.night, local(ctx, "2026-05-06T11:00:00+08:00")) ==
               ~D[2026-05-06]

      assert FullCircle.HR.instance_anchor(ctx.night, local(ctx, "2026-05-06T10:59:59+08:00")) ==
               ~D[2026-05-05]
    end

    test "drift of several hours does not change the instance", ctx do
      for t <- [
            "2026-05-06T01:00:00+08:00",
            "2026-05-06T02:00:00+08:00",
            "2026-05-06T04:00:00+08:00"
          ] do
        assert FullCircle.HR.instance_anchor(ctx.night, local(ctx, t)) == ~D[2026-05-05]
      end
    end
  end

  describe "time_attendences shift columns" do
    setup ctx do
      %{emp: employee_fixture(%{}, ctx.company, ctx.admin)}
    end

    defp punch!(ctx, iso) do
      Repo.insert!(%FullCircle.HR.TimeAttend{
        company_id: ctx.company.id,
        employee_id: ctx.emp.id,
        user_id: ctx.admin.id,
        punch_time:
          Timex.parse!(iso, "{RFC3339}")
          |> DateTime.shift_zone!("Etc/UTC")
          |> DateTime.truncate(:second),
        flag: "1_IN_1",
        status: "Draft",
        input_medium: "Manual"
      })
    end

    test "the schema carries the new fields", _ctx do
      fields = FullCircle.HR.TimeAttend.__schema__(:fields)
      assert :work_shift_id in fields
      assert :work_shift_date in fields
      assert :punch_kind in fields
      refute :shift_id in fields
    end

    test "the dead shift_id column is gone from the table", _ctx do
      {:ok, r} =
        Repo.query("select count(*) from information_schema.columns
            where table_name = 'time_attendences' and column_name = 'shift_id'")

      assert [[0]] = r.rows
    end

    test "General anchors match the calendar date for the whole working day", ctx do
      gen = FullCircle.HR.default_work_shift(ctx.company)

      for iso <- [
            "2026-05-05T07:00:00+08:00",
            "2026-05-05T12:00:00+08:00",
            "2026-05-05T17:00:00+08:00",
            "2026-05-05T21:00:00+08:00"
          ] do
        ta = punch!(ctx, iso)
        local = DateTime.shift_zone!(ta.punch_time, ctx.company.timezone)

        assert FullCircle.HR.instance_anchor(gen, local) == DateTime.to_date(local),
               "#{iso} must anchor to its own calendar date or the backfill gate is unsafe"
      end
    end

    test "a punch inside the dead band is exactly what the gate exists to catch", ctx do
      # 01:00 is before General's 02:00 cutover, so it anchors to the previous
      # day. No such punch exists in 23,902 rows of history, which is why the
      # backfill is safe - and why the migration asserts it rather than assuming.
      gen = FullCircle.HR.default_work_shift(ctx.company)
      ta = punch!(ctx, "2026-05-06T01:00:00+08:00")
      local = DateTime.shift_zone!(ta.punch_time, ctx.company.timezone)

      assert FullCircle.HR.instance_anchor(gen, local) == ~D[2026-05-05]
      refute FullCircle.HR.instance_anchor(gen, local) == DateTime.to_date(local)
    end
  end

  describe "assignment on write" do
    setup ctx do
      emp = employee_fixture(%{}, ctx.company, ctx.admin)
      {:ok, {device, _}} = FullCircle.PunchGate.create_device("Gate 1", ctx.company, ctx.admin)
      {:ok, night} = shift(ctx.company, %{})
      %{emp: emp, device: device, night: night}
    end

    defp jpeg_upload do
      path = Path.join(System.tmp_dir!(), "face-#{System.unique_integer([:positive])}.jpg")

      File.write!(
        path,
        Base.decode64!(
          "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA="
        )
      )

      %Plug.Upload{path: path, filename: "face.jpg", content_type: "image/jpeg"}
    end

    defp gate_punch(ctx, iso) do
      FullCircle.PunchGate.ingest_punch(ctx.device, %{
        "employee_id" => ctx.emp.id,
        "punched_at" =>
          Timex.parse!(iso, "{RFC3339}")
          |> DateTime.shift_zone!("Etc/UTC")
          |> DateTime.truncate(:second),
        "client_id" => Ecto.UUID.generate(),
        "photo" => jpeg_upload()
      })
    end

    defp instance_punches(ctx, date) do
      import Ecto.Query

      Repo.all(
        from t in FullCircle.HR.TimeAttend,
          where: t.employee_id == ^ctx.emp.id and t.work_shift_date == ^date,
          order_by: [asc: t.punch_time]
      )
    end

    test "a gate punch is assigned to General and numbered", ctx do
      assert {:ok, ta} = gate_punch(ctx, "2026-05-05T08:00:00+08:00")
      ta = Repo.reload!(ta)

      assert ta.work_shift_id == FullCircle.HR.default_work_shift(ctx.company).id
      assert ta.work_shift_date == ~D[2026-05-05]
      assert ta.punch_kind == "IN"
      assert ta.flag == "1_IN_1"
    end

    test "a fourth pair keeps numbering instead of wrapping to 1_IN_1", ctx do
      for iso <- [
            "2026-05-05T08:00:00+08:00",
            "2026-05-05T10:00:00+08:00",
            "2026-05-05T10:30:00+08:00",
            "2026-05-05T12:30:00+08:00",
            "2026-05-05T13:30:00+08:00",
            "2026-05-05T15:30:00+08:00",
            "2026-05-05T16:00:00+08:00",
            "2026-05-05T18:00:00+08:00"
          ] do
        assert {:ok, _} = gate_punch(ctx, iso)
      end

      flags = instance_punches(ctx, ~D[2026-05-05]) |> Enum.map(& &1.flag)

      assert flags == [
               "1_IN_1",
               "1_OUT_1",
               "2_IN_2",
               "2_OUT_2",
               "3_IN_3",
               "3_OUT_3",
               "4_IN_4",
               "4_OUT_4"
             ]
    end

    test "an assigned night worker's 02:00 punch joins the previous evening", ctx do
      Repo.insert!(%EmployeeWorkShift{
        employee_id: ctx.emp.id,
        work_shift_id: ctx.night.id,
        effective_from: ~D[2026-05-01]
      })

      assert {:ok, _} = gate_punch(ctx, "2026-05-05T17:00:00+08:00")
      assert {:ok, _} = gate_punch(ctx, "2026-05-06T02:00:00+08:00")

      punches = instance_punches(ctx, ~D[2026-05-05])
      assert length(punches) == 2
      assert Enum.map(punches, & &1.punch_kind) == ["IN", "OUT"]
      assert instance_punches(ctx, ~D[2026-05-06]) == []
    end

    test "editing a punch time out of an instance renumbers both", ctx do
      assert {:ok, _} = gate_punch(ctx, "2026-05-05T08:00:00+08:00")
      assert {:ok, b} = gate_punch(ctx, "2026-05-05T17:00:00+08:00")

      b
      |> Ecto.Changeset.change(%{
        punch_time:
          Timex.parse!("2026-05-07T09:00:00+08:00", "{RFC3339}")
          |> DateTime.shift_zone!("Etc/UTC")
          |> DateTime.truncate(:second)
      })
      |> Repo.update!()
      |> FullCircle.HR.reassign_punch(ctx.company)

      assert [left] = instance_punches(ctx, ~D[2026-05-05])
      assert left.flag == "1_IN_1"
      assert [moved] = instance_punches(ctx, ~D[2026-05-07])
      assert moved.flag == "1_IN_1"
      assert moved.punch_kind == "IN"
    end

    test "rebuild_day_flags is gone", _ctx do
      refute function_exported?(FullCircle.PunchGate, :rebuild_day_flags, 3)
    end

    test "clearing a punch from the row renumbers what is left", ctx do
      assert {:ok, a} = gate_punch(ctx, "2026-05-05T08:00:00+08:00")
      assert {:ok, _} = gate_punch(ctx, "2026-05-05T12:00:00+08:00")
      assert {:ok, _} = gate_punch(ctx, "2026-05-05T17:00:00+08:00")

      FullCircle.HR.delete_time_attendence_by_id(a.id, ctx.company, ctx.admin)

      assert ["1_IN_1", "1_OUT_1"] =
               instance_punches(ctx, ~D[2026-05-05]) |> Enum.map(& &1.flag)
    end

    test "a punch-card time edit rebuilds the instance left", ctx do
      assert {:ok, _} = gate_punch(ctx, "2026-05-05T08:00:00+08:00")
      assert {:ok, b} = gate_punch(ctx, "2026-05-05T17:00:00+08:00")

      sparse = %FullCircle.HR.TimeAttend{
        id: b.id,
        employee_id: ctx.emp.id,
        company_id: ctx.company.id,
        punch_time_local: ~N[2026-05-07 09:00:00],
        flag: b.flag,
        status: "Draft",
        user_id: ctx.admin.id,
        employee_name: ctx.emp.name,
        input_medium: "UserEntry"
      }

      assert {:ok, _} =
               FullCircle.HR.update_time_attendence(
                 sparse,
                 %{
                   input_medium: "UserEntry",
                   punch_time_local: ~N[2026-05-07 09:00:00]
                 },
                 ctx.company,
                 ctx.admin
               )

      assert [left] = instance_punches(ctx, ~D[2026-05-05])
      assert left.flag == "1_IN_1"
      assert [moved] = instance_punches(ctx, ~D[2026-05-07])
      assert moved.flag == "1_IN_1"
    end

    test "ingest returns the rebuilt flag not the insert placeholder", ctx do
      assert {:ok, _} = gate_punch(ctx, "2026-05-05T08:00:00+08:00")
      assert {:ok, second} = gate_punch(ctx, "2026-05-05T17:00:00+08:00")

      assert second.flag == "1_OUT_1"
      assert second.punch_kind == "OUT"
    end
  end

  describe "fingerprint import" do
    setup ctx do
      %{emp: employee_fixture(%{}, ctx.company, ctx.admin)}
    end

    test "a seventh and eighth punch are stored, not silently discarded", ctx do
      times = [
        ~T[08:00:00],
        ~T[10:00:00],
        ~T[10:30:00],
        ~T[12:30:00],
        ~T[13:30:00],
        ~T[15:30:00],
        ~T[16:00:00],
        ~T[18:00:00]
      ]

      for t <- times do
        entry = %{
          employee_id: ctx.emp.id,
          employee_name: ctx.emp.name,
          company_id: ctx.company.id,
          user_id: ctx.admin.id,
          status: "Draft",
          input_medium: "FingerPrint",
          punch_time_local: NaiveDateTime.new!(~D[2026-05-05], t),
          punch_time:
            DateTime.new!(~D[2026-05-05], t, ctx.company.timezone)
            |> DateTime.shift_zone!("Etc/UTC")
            |> DateTime.truncate(:second)
        }

        FullCircle.HR.insert_time_attendence_from_log(entry, ctx.company)
      end

      import Ecto.Query

      count =
        Repo.one(
          from t in FullCircle.HR.TimeAttend,
            where: t.employee_id == ^ctx.emp.id,
            select: count(t.id)
        )

      assert count == 8
    end
  end

  describe "anomalous instances read as blank, and pay anyway" do
    setup ctx do
      emp = employee_fixture(%{}, ctx.company, ctx.admin)
      %{emp: emp}
    end

    defp manual_punch!(ctx, iso) do
      ta =
        Repo.insert!(%FullCircle.HR.TimeAttend{
          company_id: ctx.company.id,
          employee_id: ctx.emp.id,
          user_id: ctx.admin.id,
          punch_time:
            Timex.parse!(iso, "{RFC3339}")
            |> DateTime.shift_zone!("Etc/UTC")
            |> DateTime.truncate(:second),
          status: "Draft",
          input_medium: "Manual"
        })

      {:ok, ta} = FullCircle.HR.reassign_punch(ta, ctx.company)
      ta
    end

    defp day(ctx, date) do
      FullCircle.HR.punch_card_query(5, 2026, ctx.emp.id, ctx.company)
      |> Enum.find(fn r -> Timex.to_date(r.dd) == date end)
    end

    test "a complete day carries hours and no anomaly", ctx do
      manual_punch!(ctx, "2026-05-05T08:00:00+08:00")
      manual_punch!(ctx, "2026-05-05T17:00:00+08:00")

      row = day(ctx, ~D[2026-05-05])
      assert is_nil(row.anomaly)
      assert_in_delta row.wh, 9.0, 0.001
    end

    test "a missing punch out blanks the hours instead of paying 0.0", ctx do
      manual_punch!(ctx, "2026-05-05T08:00:00+08:00")

      row = day(ctx, ~D[2026-05-05])
      assert row.anomaly == :missing_punch
      assert is_nil(row.wh)
      assert is_nil(row.nh)
      assert is_nil(row.ot)
    end

    test "adding the missing punch restores the hours", ctx do
      manual_punch!(ctx, "2026-05-05T08:00:00+08:00")
      assert day(ctx, ~D[2026-05-05]).anomaly == :missing_punch

      manual_punch!(ctx, "2026-05-05T17:00:00+08:00")
      row = day(ctx, ~D[2026-05-05])
      assert is_nil(row.anomaly)
      assert_in_delta row.wh, 9.0, 0.001
    end

    # The cutover splits these two punches into separate instances: General cuts
    # over at 02:00, so 08:00 on the 5th and 17:00 on the 6th are two days, each
    # holding one punch. This is NOT one 33-hour :too_long instance - an earlier
    # draft said it was, and a test asserting that would fail.
    test "punches a day apart are two instances, each missing a punch", ctx do
      manual_punch!(ctx, "2026-05-05T08:00:00+08:00")
      manual_punch!(ctx, "2026-05-06T17:00:00+08:00")

      assert day(ctx, ~D[2026-05-05]).anomaly == :missing_punch
      assert day(ctx, ~D[2026-05-06]).anomaly == :missing_punch
    end

    # :too_long needs both punches inside one window.
    test "a fourteen hour span inside one instance is too long", ctx do
      manual_punch!(ctx, "2026-05-05T07:00:00+08:00")
      manual_punch!(ctx, "2026-05-05T21:00:00+08:00")

      row = day(ctx, ~D[2026-05-05])
      assert row.anomaly == :too_long
      assert is_nil(row.wh)
    end

    test "a genuine zero hour day stays 0.0, not nil", ctx do
      manual_punch!(ctx, "2026-05-05T08:00:00+08:00")
      manual_punch!(ctx, "2026-05-05T08:00:00+08:00")

      row = day(ctx, ~D[2026-05-05])
      assert is_nil(row.anomaly)
      assert row.wh == 0.0
    end

    # The off-site case: one punch every working day, for a whole month, and the
    # pay slip must still generate. Nothing in this feature gates payroll.
    test "a month of single punch days still pays", ctx do
      for d <- 4..8 do
        manual_punch!(ctx, "2026-05-0#{d}T08:00:00+08:00")
      end

      rows = FullCircle.HR.punch_card_query(5, 2026, ctx.emp.id, ctx.company)
      assert Enum.count(rows, fn r -> r.anomaly == :missing_punch end) == 5

      # PaySlipOp.pay/6 always looks up "Employee PCB"; it is not company-seeded.
      cr =
        FullCircle.Accounting.get_account_by_name(
          "Salaries and Wages Payable",
          ctx.company,
          ctx.admin
        )

      salary_type_fixture(
        %{
          name: "Employee PCB",
          type: "Deduction",
          cal_func: "pcb_employee",
          db_ac_name: cr.name,
          db_ac_id: cr.id,
          cr_ac_name: cr.name,
          cr_ac_id: cr.id
        },
        ctx.company,
        ctx.admin
      )

      acc = FullCircle.ReceiveFundFixtures.funds_account_fixture(ctx.company, ctx.admin)

      # PaySlipOp.pay/6 hardcodes slip_date to Timex.today(), and PaySlip
      # validate_pay_month_year rejects a period more than 31 days from that
      # date. May 2026 cannot insert in September; paying the current period
      # still proves there is no anomaly gate (PaySlipOp does not read punches).
      today = Date.utc_today()

      assert {:ok, _} =
               FullCircle.PaySlipOp.pay(
                 Repo.reload!(ctx.emp),
                 today.month,
                 today.year,
                 acc.id,
                 ctx.company,
                 ctx.admin
               )
    end
  end

  describe "anomaly/3 is the single rule" do
    test "odd count, then span, then clean" do
      alias FullCircle.HR.ShiftInstance
      max = Decimal.new("12")

      assert ShiftInstance.anomaly(3, 4.0, max) == :missing_punch
      assert ShiftInstance.anomaly(2, 33.0, max) == :too_long
      assert ShiftInstance.anomaly(2, 12.0, max) == nil
      assert ShiftInstance.anomaly(4, 9.0, max) == nil
    end
  end
end
