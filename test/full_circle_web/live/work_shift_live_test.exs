defmodule FullCircleWeb.WorkShiftLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.UserAccountsFixtures
  import FullCircle.SysFixtures
  import FullCircle.HRFixtures

  alias FullCircle.Repo
  alias FullCircle.HR
  alias FullCircle.HR.{WorkShift, EmployeeWorkShift, TimeAttend}

  setup %{conn: conn} do
    user = user_fixture()
    comp = company_fixture(user, %{})
    %{conn: log_in_user(conn, user), user: user, comp: comp}
  end

  defp member_conn(comp, role) do
    u = user_fixture()

    Repo.insert!(%FullCircle.Sys.CompanyUser{
      company_id: comp.id,
      user_id: u.id,
      role: role
    })

    build_conn() |> log_in_user(u)
  end

  defp shift(comp, attrs) do
    %WorkShift{}
    |> WorkShift.changeset(
      Map.merge(
        %{
          company_id: comp.id,
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

  test "lists the seeded General shift with its derived times", %{conn: conn, comp: comp} do
    {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/work_shifts")

    assert html =~ "Work Shifts"
    assert html =~ "General"
    assert html =~ "08:00"
    # nominal end and cutover are shown so the arithmetic is never a mystery
    assert html =~ "17:00"
    assert html =~ "02:00"
  end

  test "creates a night shift and shows its derived cutover", %{conn: conn, comp: comp} do
    {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/work_shifts/new")

    {:ok, _lv, html} =
      lv
      |> form("#work-shift-form",
        work_shift: %{
          name: "Night",
          start_time: "17:00",
          normal_hour: "9",
          max_hour: "12"
        }
      )
      |> render_submit()
      |> follow_redirect(conn)

    assert html =~ "Night"
    ws = Repo.get_by!(FullCircle.HR.WorkShift, company_id: comp.id, name: "Night")
    assert FullCircle.HR.WorkShift.cutover_time(ws) == ~T[11:00:00]
    refute ws.is_default
  end

  test "rejects max_hour below normal_hour", %{conn: conn, comp: comp} do
    {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/work_shifts/new")

    html =
      lv
      |> form("#work-shift-form",
        work_shift: %{name: "Bad", start_time: "08:00", normal_hour: "12", max_hour: "9"}
      )
      |> render_submit()

    assert html =~ "must not be less than normal hour"
  end

  test "a clerk is bounced to the dashboard", %{comp: comp} do
    assert {:error, {:live_redirect, %{to: to}}} =
             live(member_conn(comp, "clerk"), ~p"/companies/#{comp.id}/work_shifts")

    assert to == "/companies/#{comp.id}/dashboard"
  end

  test "a supervisor is allowed in", %{comp: comp} do
    {:ok, _lv, html} =
      live(member_conn(comp, "supervisor"), ~p"/companies/#{comp.id}/work_shifts")

    assert html =~ "Work Shifts"
  end

  test "the default shift cannot be deleted", ctx do
    gen = FullCircle.HR.default_work_shift(ctx.comp)
    assert {:error, :default_shift} = FullCircle.HR.delete_work_shift(gen, ctx.comp, ctx.user)
  end

  test "a shift with punches cannot be deleted", ctx do
    {:ok, night} = shift(ctx.comp, %{})
    emp = employee_fixture(%{}, ctx.comp, ctx.user)

    Repo.insert!(%EmployeeWorkShift{
      employee_id: emp.id,
      work_shift_id: night.id,
      effective_from: ~D[2026-05-01]
    })

    %TimeAttend{
      company_id: ctx.comp.id,
      employee_id: emp.id,
      user_id: ctx.user.id,
      punch_time:
        Timex.parse!("2026-05-05T17:00:00+08:00", "{RFC3339}")
        |> DateTime.shift_zone!("Etc/UTC")
        |> DateTime.truncate(:second),
      status: "Draft",
      input_medium: "Manual"
    }
    |> Repo.insert!()
    |> HR.reassign_punch(ctx.comp)

    assert {:error, :shift_in_use} = HR.delete_work_shift(night, ctx.comp, ctx.user)
  end

  test "a shift still assigned to an employee cannot be deleted", ctx do
    {:ok, night} = shift(ctx.comp, %{})
    emp = employee_fixture(%{}, ctx.comp, ctx.user)

    Repo.insert!(%EmployeeWorkShift{
      employee_id: emp.id,
      work_shift_id: night.id,
      effective_from: ~D[2026-05-01]
    })

    assert {:error, :shift_assigned} = HR.delete_work_shift(night, ctx.comp, ctx.user)
  end

  test "an unused non-default shift can be deleted", ctx do
    {:ok, night} = shift(ctx.comp, %{})
    assert {:ok, _} = HR.delete_work_shift(night, ctx.comp, ctx.user)
    refute Repo.get(WorkShift, night.id)
  end

  test "moving the cutover re-resolves that shift's punches", ctx do
    # Night 17:00/12 -> cutover 11:00, so a 02:00 punch anchors to the day before.
    {:ok, night} = shift(ctx.comp, %{})
    emp = employee_fixture(%{}, ctx.comp, ctx.user)

    Repo.insert!(%EmployeeWorkShift{
      employee_id: emp.id,
      work_shift_id: night.id,
      effective_from: ~D[2026-05-01]
    })

    {:ok, ta} =
      %TimeAttend{
        company_id: ctx.comp.id,
        employee_id: emp.id,
        user_id: ctx.user.id,
        punch_time:
          Timex.parse!("2026-05-06T02:00:00+08:00", "{RFC3339}")
          |> DateTime.shift_zone!("Etc/UTC")
          |> DateTime.truncate(:second),
        status: "Draft",
        input_medium: "Manual"
      }
      |> Repo.insert!()
      |> HR.reassign_punch(ctx.comp)

    assert Repo.reload!(ta).work_shift_date == ~D[2026-05-05]
    assert WorkShift.cutover_time(night) == ~T[11:00:00]

    # Changing start_time to 08:00 moves the cutover to 02:00 (General's
    # arithmetic). A 02:00 punch is then on the cutover, so it opens its own
    # calendar date. Widening max_hour on a 17:00 start only moves the cutover
    # later (still after 02:00), so start_time is the field that can actually
    # re-anchor this punch.
    assert {:ok, updated} =
             HR.save_work_shift(night, %{"start_time" => "08:00"}, ctx.comp, ctx.user)

    assert WorkShift.cutover_time(updated) == ~T[02:00:00]
    assert Repo.reload!(ta).work_shift_date == ~D[2026-05-06]
  end
end
