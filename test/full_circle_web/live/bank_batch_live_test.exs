defmodule FullCircleWeb.BankBatchLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.BillingFixtures
  import FullCircle.BankPaymentFixtures

  alias FullCircle.BankPayment

  setup do
    admin = user_fixture()
    com = company_fixture(admin, %{})
    install_template!(com, admin, "pbb_ecp_payment")
    bank = bank_gl_account_fixture(com, admin)

    profile =
      profile_fixture(com, admin, bank, %{
        "format_code" => "pbb_ecp_payment",
        "our_account_no" => "3999999999",
        "params" => %{}
      })

    supplier =
      bank_contact_fixture(com, admin, %{
        "bank_code" => "PBBEMYKL",
        "bank_account_no" => "3123456789"
      })

    p = bank_payment_fixture(com, admin, supplier, bank, "321.00")
    mgr = user_fixture()
    FullCircle.Sys.allow_user_to_access(com, mgr, "manager", admin)

    %{
      admin: admin,
      com: com,
      bank: bank,
      profile: profile,
      supplier: supplier,
      p: p,
      mgr_conn: log_in_user(build_conn(), mgr)
    }
  end

  test "tick, create, download, submit, import result", %{com: com, p: p, mgr_conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/companies/#{com.id}/bank_batches")
    assert html =~ p.payment_no

    lv |> element("#tick-#{p.id}") |> render_click()
    assert render(lv) =~ "1 ticked, total 321.00"

    lv |> element("#create-file") |> render_click()
    assert_push_event(lv, "download", %{url: url})
    refute render(lv) =~ "tick-#{p.id}"

    resp = get(conn, url)
    assert resp.status == 200
    assert [cd] = get_resp_header(resp, "content-disposition")
    assert cd =~ "3999999999PM"

    [batch] = BankPayment.list_batches(com)
    lv |> element("#submit-#{batch.id}") |> render_click()
    assert render(lv) =~ "submitted"
    refute has_element?(lv, "#void-#{batch.id}")

    [line] = BankPayment.batch_lines(batch.id, com)

    text =
      psf_text(Path.rootname(batch.filename), [
        {String.pad_leading("#{line.record_no}", 12, "0"), 32_100, "01", ""}
      ])

    assert lv |> element("#result-upload-form") |> render() =~ "phx-change"

    upload =
      file_input(lv, "#result-upload-form", :result, [
        %{name: "PSF#{batch.filename}", content: text, type: "text/plain"}
      ])

    html = render_upload(upload, "PSF#{batch.filename}")
    assert html =~ "1 paid"
    assert html =~ "completed"
  end

  test "download again needs a reason", %{
    com: com,
    p: p,
    profile: profile,
    admin: admin,
    mgr_conn: conn
  } do
    {:ok, [b]} =
      BankPayment.create_batches(profile.id, [p.id], BankPayment.today(com), com, admin)

    assert get(conn, ~p"/companies/#{com.id}/bank_batches/download?#{[ids: b.id]}").status == 200
    assert get(conn, ~p"/companies/#{com.id}/bank_batches/download?#{[ids: b.id]}").status == 422

    {:ok, lv, _} = live(conn, ~p"/companies/#{com.id}/bank_batches")
    lv |> element("#download-again-#{b.id}") |> render_click()
    lv |> form("#action-form", %{"reason" => "lost the file"}) |> render_submit()
    assert_push_event(lv, "download", %{url: url})
    assert url =~ "reason=lost"
  end

  test "duplicate warning then Create anyway", %{
    com: com,
    supplier: supplier,
    bank: bank,
    p: p,
    profile: profile,
    admin: admin,
    mgr_conn: conn
  } do
    {:ok, _} = BankPayment.create_batches(profile.id, [p.id], BankPayment.today(com), com, admin)
    p2 = bank_payment_fixture(com, admin, supplier, bank, "321.00")
    {:ok, lv, _} = live(conn, ~p"/companies/#{com.id}/bank_batches")
    lv |> element("#tick-#{p2.id}") |> render_click()
    assert lv |> element("#create-file") |> render_click() =~ p.payment_no
    lv |> element("#create-anyway") |> render_click()
    assert_push_event(lv, "download", %{url: _})
  end

  test "paid outside file and undo; greyed row without bank details", %{
    com: com,
    admin: admin,
    bank: bank,
    p: p,
    mgr_conn: conn
  } do
    nob = bank_payment_fixture(com, admin, contact_fixture(com, admin), bank)
    {:ok, lv, html} = live(conn, ~p"/companies/#{com.id}/bank_batches")
    assert html =~ "no bank details"
    refute has_element?(lv, "#tick-#{nob.id}")

    lv |> element("#dismiss-#{p.id}") |> render_click()
    lv |> form("#action-form", %{"reason" => "cheque 1234"}) |> render_submit()
    refute has_element?(lv, "#tick-#{p.id}")

    lv |> element("#show-dismissed") |> render_click()
    lv |> element("#undismiss-#{p.id}") |> render_click()
    assert has_element?(lv, "#tick-#{p.id}")
  end

  test "clerks are sent away and cannot download", %{admin: admin, com: com} do
    clerk = user_fixture()
    FullCircle.Sys.allow_user_to_access(com, clerk, "clerk", admin)
    conn = log_in_user(build_conn(), clerk)
    assert {:error, {:live_redirect, _}} = live(conn, ~p"/companies/#{com.id}/bank_batches")

    assert get(
             conn,
             ~p"/companies/#{com.id}/bank_batches/download?#{[ids: Ecto.UUID.generate()]}"
           ).status == 403
  end

  test "download again of a batch voided in another tab shows an error instead of leaving",
       %{com: com, p: p, profile: profile, admin: admin, mgr_conn: conn} do
    {:ok, [b]} =
      BankPayment.create_batches(profile.id, [p.id], BankPayment.today(com), com, admin)

    {:ok, _} = BankPayment.download_files([b.id], nil, com, admin)
    {:ok, lv, _} = live(conn, ~p"/companies/#{com.id}/bank_batches")
    {:ok, _} = BankPayment.void_batch(b.id, "never uploaded", com, admin)

    lv |> element("#download-again-#{b.id}") |> render_click()
    html = lv |> form("#action-form", %{"reason" => "again"}) |> render_submit()
    assert html =~ "voided"
    refute_push_event(lv, "download", %{url: _})
  end

  test "upload errors are shown", %{com: com, mgr_conn: conn} do
    {:ok, lv, _} = live(conn, ~p"/companies/#{com.id}/bank_batches")

    upload =
      file_input(lv, "#result-upload-form", :result, [
        %{name: "x.pdf", content: "x", type: "application/pdf"}
      ])

    render_upload(upload, "x.pdf")
    assert render(lv) =~ "not accepted"
  end

  test "a ticked row that leaves the list is no longer counted", %{com: com, p: p, mgr_conn: conn} do
    {:ok, lv, _} = live(conn, ~p"/companies/#{com.id}/bank_batches")
    lv |> element("#tick-#{p.id}") |> render_click()
    lv |> element("#dismiss-#{p.id}") |> render_click()
    html = lv |> form("#action-form", %{"reason" => "cheque"}) |> render_submit()
    assert html =~ "0 ticked, total 0.00"
  end

  test "rows show a short bank name and the full account number", %{
    com: com,
    p: p,
    mgr_conn: conn
  } do
    {:ok, lv, _} = live(conn, ~p"/companies/#{com.id}/bank_batches")
    row = lv |> element("#row-#{p.id}") |> render()
    # The full name stays in the hover title; the visible text is the short name.
    assert row =~ ">Public Bank<"
    refute row =~ ">Public Bank Berhad<"
    assert row =~ "3123456789"
  end

  test "payment numbers open the Payment in a new tab", %{com: com, p: p, mgr_conn: conn} do
    {:ok, lv, _} = live(conn, ~p"/companies/#{com.id}/bank_batches")
    row = lv |> element("#row-#{p.id}") |> render()
    assert row =~ ~s|href="/companies/#{com.id}/Payment/#{p.id}/edit"|
    assert row =~ ~s|target="_blank"|
  end

  test "supplier names open the contact in a new tab", %{
    com: com,
    p: p,
    supplier: supplier,
    profile: profile,
    admin: admin,
    mgr_conn: conn
  } do
    {:ok, lv, _} = live(conn, ~p"/companies/#{com.id}/bank_batches")
    href = ~s|href="/companies/#{com.id}/contacts/#{supplier.id}/edit"|
    row = lv |> element("#row-#{p.id}") |> render()
    assert row =~ href
    assert row =~ ~s|target="_blank"|

    {:ok, [b]} =
      BankPayment.create_batches(profile.id, [p.id], BankPayment.today(com), com, admin)

    {:ok, lv, _} = live(conn, ~p"/companies/#{com.id}/bank_batches")
    lv |> element("#open-#{b.id}") |> render_click()
    assert lv |> element("#batch-#{b.id}") |> render() =~ href
  end
end
