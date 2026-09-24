defmodule FullCircleWeb.CrossCompanyScopingTest do
  @moduledoc """
  The edit forms used to load their record with `StdInterface.get!/2`, an
  unscoped `Repo.get!`, so the id in the URL alone decided what came back and
  another company's record rendered. `get_by_id!/4` joins through
  `Sys.user_company/2` instead.

  Each entity is checked both ways: the form still opens its own record, and it
  refuses one belonging to somebody else.
  """
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.AccountingFixtures
  import FullCircle.BillingFixtures
  import FullCircle.HRFixtures

  alias FullCircle.Repo

  setup %{conn: conn} do
    user = user_fixture()
    com = company_fixture(user, %{name: "Mine Sdn Bhd"})

    intruder = user_fixture()
    other = company_fixture(intruder, %{name: "Theirs Sdn Bhd"})

    %{conn: log_in_user(conn, user), user: user, com: com, other: other, stranger: intruder}
  end

  defp work_shift(com, name) do
    Repo.insert!(%FullCircle.HR.WorkShift{
      name: name,
      start_time: ~T[08:00:00],
      normal_hour: Decimal.new("9"),
      max_hour: Decimal.new("12"),
      company_id: com.id
    })
  end

  defp weighing(com, note_no) do
    Repo.insert!(%FullCircle.WeightBridge.Weighing{
      note_no: note_no,
      note_date: ~D[2026-09-01],
      vehicle_no: "ABC 1234",
      good_name: "Maize",
      gross: 20_000,
      tare: 8_000,
      company_id: com.id
    })
  end

  describe "accounts" do
    test "opens its own", %{conn: conn, com: com, user: user} do
      ac = account_fixture(%{name: "Mine Cash"}, com, user)
      {:ok, _lv, html} = live(conn, ~p"/companies/#{com.id}/accounts/#{ac.id}/edit")
      assert html =~ "Mine Cash"
    end

    test "refuses another company's", %{conn: conn, com: com, other: other, stranger: stranger} do
      theirs = account_fixture(%{name: "Their Cash"}, other, stranger)

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/companies/#{com.id}/accounts/#{theirs.id}/edit")
      end
    end
  end

  describe "contacts" do
    test "opens its own", %{conn: conn, com: com, user: user} do
      c = contact_fixture(com, user, %{"name" => "Mine Contact"})
      {:ok, _lv, html} = live(conn, ~p"/companies/#{com.id}/contacts/#{c.id}/edit")
      assert html =~ "Mine Contact"
    end

    test "refuses another company's", %{conn: conn, com: com, other: other, stranger: stranger} do
      theirs = contact_fixture(other, stranger, %{"name" => "Their Contact"})

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/companies/#{com.id}/contacts/#{theirs.id}/edit")
      end
    end
  end

  describe "holidays" do
    test "opens its own, and copies it", %{conn: conn, com: com, user: user} do
      h = holiday_fixture(%{}, com, user)

      assert {:ok, _lv, _html} = live(conn, ~p"/companies/#{com.id}/holidays/#{h.id}/edit")
      assert {:ok, _lv, _html} = live(conn, ~p"/companies/#{com.id}/holidays/#{h.id}/copy")
    end

    test "refuses another company's, on edit and on copy", %{
      conn: conn,
      com: com,
      other: other,
      stranger: stranger
    } do
      theirs = holiday_fixture(%{}, other, stranger)

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/companies/#{com.id}/holidays/#{theirs.id}/edit")
      end

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/companies/#{com.id}/holidays/#{theirs.id}/copy")
      end
    end
  end

  describe "work shifts" do
    test "opens its own", %{conn: conn, com: com} do
      ws = work_shift(com, "Mine Shift")
      {:ok, _lv, html} = live(conn, ~p"/companies/#{com.id}/work_shifts/#{ws.id}/edit")
      assert html =~ "Mine Shift"
    end

    test "refuses another company's", %{conn: conn, com: com, other: other} do
      theirs = work_shift(other, "Their Shift")

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/companies/#{com.id}/work_shifts/#{theirs.id}/edit")
      end
    end
  end

  describe "weighings" do
    test "opens its own", %{conn: conn, com: com} do
      w = weighing(com, "WB-0001")
      {:ok, _lv, html} = live(conn, ~p"/companies/#{com.id}/Weighing/#{w.id}/edit")
      assert html =~ "WB-0001"
    end

    test "refuses another company's", %{conn: conn, com: com, other: other} do
      theirs = weighing(other, "WB-9999")

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/companies/#{com.id}/Weighing/#{theirs.id}/edit")
      end
    end
  end
end
