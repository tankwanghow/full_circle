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
end
