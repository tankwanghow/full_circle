defmodule FullCircleWeb.ContactLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.BillingFixtures

  setup %{conn: conn} do
    user = user_fixture()
    comp = company_fixture(user, %{})

    contact =
      contact_fixture(comp, user, %{
        "name" => "TESTCONTACT",
        "country" => "Malaysia",
        "city" => "Kuala Lumpur",
        "state" => "WP",
        "address1" => "123 Main St"
      })

    %{conn: log_in_user(conn, user), user: user, comp: comp, contact: contact}
  end

  describe "data value" do
    setup %{conn: conn, comp: comp, contact: contact} do
      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/contacts/#{contact.id}/edit")
      %{conn: conn, lv: lv, html: html, obj: contact}
    end

    test_input_value("contact", "input", :text, "name")
    test_input_value("contact", "input", :text, "country")
    test_input_value("contact", "input", :text, "city")
    test_input_value("contact", "input", :text, "state")
    test_input_value("contact", "input", :text, "address1")
  end

  describe "data validation" do
    setup %{conn: conn, comp: comp} do
      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/contacts/new")
      %{conn: conn, lv: lv, html: html}
    end

    test "name can't be blank", %{lv: lv} do
      html =
        lv
        |> element("#object-form")
        |> render_change(%{contact: %{name: ""}})

      text =
        html |> LazyHTML.from_fragment() |> LazyHTML.query(~s|p.text-rose-600|) |> LazyHTML.text()

      assert text =~ "can't be blank"
    end

    test "name has already been taken", %{lv: lv} do
      html =
        lv
        |> element("#object-form")
        |> render_change(%{contact: %{name: "TESTCONTACT"}})

      text =
        html |> LazyHTML.from_fragment() |> LazyHTML.query(~s|p.text-rose-600|) |> LazyHTML.text()

      assert text =~ "has already been taken"
    end

    test "country not in list", %{lv: lv} do
      html =
        lv
        |> element("#object-form")
        |> render_change(%{contact: %{country: "not a country"}})

      text =
        html |> LazyHTML.from_fragment() |> LazyHTML.query(~s|p.text-rose-600|) |> LazyHTML.text()

      assert text =~ "not in list"
    end
  end

  describe "Edit" do
    setup %{conn: conn, comp: comp, contact: contact} do
      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/contacts/#{contact.id}/edit")
      %{conn: conn, lv: lv, html: html, comp: comp, contact: contact}
    end

    test "save valid contact", %{conn: conn, lv: lv} do
      {:ok, _, html} =
        lv
        |> form("#object-form", contact: %{name: "UpdatedContact", country: "Malaysia"})
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "UpdatedContact"
      assert html =~ "Contact updated successfully"
    end

    test "save invalid contact", %{lv: lv} do
      html =
        lv
        |> form("#object-form", contact: %{name: ""})
        |> render_submit()

      assert html =~ "Failed"
      assert html =~ "Edit Contact"
    end

    test "form layout", %{html: html} do
      assert html =~ "Edit Contact"
      assert html =~ "Name\n</label>"
      assert html =~ "Category\n</label>"
      assert html =~ "Country\n</label>"
      assert html =~ "Address Line 1\n</label>"
    end
  end

  describe "New" do
    setup %{conn: conn, comp: comp} do
      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/contacts/new")
      %{conn: conn, lv: lv, html: html}
    end

    test "save valid contact", %{conn: conn, lv: lv} do
      {:ok, _, html} =
        lv
        |> form("#object-form", contact: %{name: "BrandNewContact", country: "Malaysia"})
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "BrandNewContact"
      assert html =~ "Contact created successfully"
    end

    test "save invalid contact", %{lv: lv} do
      html =
        lv
        |> form("#object-form", contact: %{})
        |> render_submit()

      assert html =~ "Failed"
      assert html =~ "New Contact"
    end

    test "form layout", %{html: html} do
      assert html =~ "New Contact"
      assert html =~ "Name\n</label>"
      assert html =~ "Category\n</label>"
      assert html =~ "Country\n</label>"
      assert html =~ "Address Line 1\n</label>"
    end
  end

  describe "Index" do
    test "layout", %{conn: conn, comp: comp} do
      {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/contacts")
      assert html =~ "Contacts Listing"

      assert LazyHTML.from_fragment(html)
             |> LazyHTML.query(~s|form input[name="search[terms]"]|)
             |> LazyHTML.to_tree() != []

      assert html =~ "Contact Information"
    end

    test "contact list", %{conn: conn, comp: comp} do
      {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/contacts")

      text =
        LazyHTML.from_fragment(html) |> LazyHTML.query(~s|div#objects_list|) |> LazyHTML.text()

      assert text =~ "TESTCONTACT"
    end
  end
end
