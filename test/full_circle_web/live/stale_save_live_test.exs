defmodule FullCircleWeb.StaleSaveLiveTest do
  @moduledoc """
  When the record behind an open edit form is deleted or changed by someone
  else, saving must show the user a flash telling them to reload — not crash
  the LiveView.
  """
  use FullCircleWeb.ConnCase

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.BillingFixtures

  alias FullCircle.Accounting.Contact

  setup %{conn: conn} do
    user = user_fixture()
    comp = company_fixture(user, %{})

    contact =
      contact_fixture(comp, user, %{
        "name" => "STALECONTACT",
        "country" => "Malaysia",
        "city" => "Kuala Lumpur",
        "state" => "WP",
        "address1" => "123 Main St"
      })

    %{conn: log_in_user(conn, user), user: user, comp: comp, contact: contact}
  end

  test "contact edit form flashes instead of crashing when the record is gone", %{
    conn: conn,
    comp: comp,
    contact: contact
  } do
    {:ok, lv, _html} = live(conn, ~p"/companies/#{comp.id}/contacts/#{contact.id}/edit")

    {1, _} = FullCircle.Repo.delete_all(from(c in Contact, where: c.id == ^contact.id))

    html =
      lv
      |> form("#object-form", contact: %{name: "RENAMED BY STALE FORM"})
      |> render_submit()

    assert html =~ "changed or deleted by someone else"
  end

  # The struct the form holds in memory is what carries lock_version into the
  # save. A loader that builds a partial struct (an explicit `select: %Good{}`,
  # say) drops the column to nil and every save from that form looks stale, so
  # this exercises the whole round trip rather than the context alone.
  test "goods edit form flashes when someone else saved the record first", %{
    conn: conn,
    comp: comp,
    user: user
  } do
    good = good_fixture(comp, user)

    {:ok, lv, _html} = live(conn, ~p"/companies/#{comp.id}/goods/#{good.id}/edit")

    other = FullCircle.Product.get_good!(good.id, comp, user)

    {:ok, _} =
      FullCircle.StdInterface.update(
        FullCircle.Product.Good,
        "good",
        other,
        %{"descriptions" => "saved by the other user"},
        comp,
        user
      )

    html =
      lv
      |> form("#object-form", good: %{descriptions: "saved by the stale form"})
      |> render_submit()

    assert html =~ "changed or deleted by someone else"
  end

  test "goods edit form still saves normally when nobody else touched the record", %{
    conn: conn,
    comp: comp,
    user: user
  } do
    good = good_fixture(comp, user)

    {:ok, lv, _html} = live(conn, ~p"/companies/#{comp.id}/goods/#{good.id}/edit")

    lv
    |> form("#object-form", good: %{descriptions: "a quiet single-user edit"})
    |> render_submit()

    assert FullCircle.Product.get_good!(good.id, comp, user).descriptions ==
             "a quiet single-user edit"
  end
end
