defmodule FullCircleWeb.ContactBankLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.BillingFixtures

  setup do
    admin = user_fixture()
    com = company_fixture(admin, %{})
    %{admin: admin, com: com, contact: contact_fixture(com, admin)}
  end

  defp conn_as(com, admin, role) do
    user = user_fixture()
    FullCircle.Sys.allow_user_to_access(com, user, role, admin)
    log_in_user(build_conn(), user)
  end

  test "a manager saves bank details and they survive a parent re-render", %{
    admin: admin,
    com: com,
    contact: contact
  } do
    {:ok, lv, html} =
      live(conn_as(com, admin, "manager"), ~p"/companies/#{com.id}/contacts/#{contact.id}/edit")

    assert html =~ "Bank details"

    lv
    |> form("#contact-bank-form", %{
      "contact_bank" => %{
        "bank_code" => "MBBEMYKL",
        "bank_account_no" => "112233445566",
        "bank_account_name" => "Tan"
      }
    })
    |> render_submit()

    assert render(lv) =~ "Saved"

    assert FullCircle.Repo.get!(FullCircle.Accounting.Contact, contact.id).bank_account_no ==
             "112233445566"

    lv |> form("#object-form", %{"contact" => %{"phone" => "012"}}) |> render_change()
    assert lv |> element("#contact-bank-form") |> render() =~ "112233445566"
  end

  test "a clerk never sees the bank block", %{admin: admin, com: com, contact: contact} do
    {:ok, _lv, html} =
      live(conn_as(com, admin, "clerk"), ~p"/companies/#{com.id}/contacts/#{contact.id}/edit")

    refute html =~ "Bank details"
    refute html =~ "contact-bank-form"
  end

  test "a manager can clear bank details", %{admin: admin, com: com, contact: contact} do
    {:ok, _} =
      FullCircle.Accounting.save_contact_bank(
        contact,
        %{
          "bank_code" => "MBBEMYKL",
          "bank_account_no" => "112233445566",
          "bank_account_name" => "Tan"
        },
        com,
        admin
      )

    {:ok, lv, _} =
      live(conn_as(com, admin, "manager"), ~p"/companies/#{com.id}/contacts/#{contact.id}/edit")

    lv
    |> form("#contact-bank-form", %{
      "contact_bank" => %{
        "bank_code" => "",
        "bank_account_no" => "",
        "bank_account_name" => "Tan"
      }
    })
    |> render_submit()

    assert render(lv) =~ "Saved"
    assert FullCircle.Repo.get!(FullCircle.Accounting.Contact, contact.id).bank_code == nil
  end
end
