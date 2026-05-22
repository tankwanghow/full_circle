defmodule FullCircleWeb.DocumentEmailControllerTest do
  use FullCircleWeb.ConnCase, async: true

  import FullCircle.BillingFixtures
  import FullCircle.SysFixtures
  import Swoosh.TestAssertions

  setup %{conn: conn} do
    user = FullCircle.UserAccountsFixtures.user_fixture()
    company = company_fixture(user, %{})
    invoice = invoice_fixture(company, user)
    %{conn: log_in_user(conn, user), user: user, company: company, invoice: invoice}
  end

  describe "POST /email_document" do
    test "sends the email and returns ok for an accessible document", %{
      conn: conn,
      company: company,
      invoice: invoice
    } do
      conn =
        post(conn, ~p"/email_document", %{
          "company_id" => company.id,
          "doc_type" => "Invoice",
          "doc_id" => invoice.id,
          "email" => "customer@example.com"
        })

      assert json_response(conn, 200) == %{"ok" => true}
      assert_email_sent(fn email -> assert {_, "customer@example.com"} = hd(email.to) end)
    end

    test "rejects an unknown doc_type", %{conn: conn, company: company, invoice: invoice} do
      conn =
        post(conn, ~p"/email_document", %{
          "company_id" => company.id,
          "doc_type" => "Nonsense",
          "doc_id" => invoice.id,
          "email" => "customer@example.com"
        })

      assert %{"ok" => false} = json_response(conn, 200)
    end

    test "rejects a document the user cannot access", %{conn: conn, company: company} do
      conn =
        post(conn, ~p"/email_document", %{
          "company_id" => company.id,
          "doc_type" => "Invoice",
          "doc_id" => Ecto.UUID.generate(),
          "email" => "customer@example.com"
        })

      assert %{"ok" => false} = json_response(conn, 200)
    end

    test "rejects a blank recipient", %{conn: conn, company: company, invoice: invoice} do
      conn =
        post(conn, ~p"/email_document", %{
          "company_id" => company.id,
          "doc_type" => "Invoice",
          "doc_id" => invoice.id,
          "email" => "   "
        })

      assert %{"ok" => false} = json_response(conn, 200)
    end

    test "rejects a malformed recipient", %{conn: conn, company: company, invoice: invoice} do
      conn =
        post(conn, ~p"/email_document", %{
          "company_id" => company.id,
          "doc_type" => "Invoice",
          "doc_id" => invoice.id,
          "email" => "not-an-email"
        })

      assert %{"ok" => false} = json_response(conn, 200)
    end
  end

  describe "GET /email_document/new" do
    test "returns the document contact's email", %{
      conn: conn,
      company: company,
      invoice: invoice
    } do
      conn =
        get(conn, ~p"/email_document/new", %{
          "company_id" => company.id,
          "doc_type" => "Invoice",
          "doc_id" => invoice.id
        })

      assert %{"recipient" => _} = json_response(conn, 200)
    end
  end

  test "requires authentication" do
    conn = post(build_conn(), ~p"/email_document", %{})
    assert redirected_to(conn) =~ "/users/log_in"
  end
end
