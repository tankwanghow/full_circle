defmodule FullCircle.BankPaymentResultTest do
  use FullCircle.DataCase

  alias FullCircle.BankPayment
  alias FullCircle.BankPayment.Result

  import FullCircle.BillingFixtures
  import FullCircle.BankPaymentFixtures

  setup do
    %{admin: admin, company: company} = billing_setup()
    install_template!(company, admin, "pbb_ecp_payment")
    bank = bank_gl_account_fixture(company, admin)

    profile =
      profile_fixture(company, admin, bank, %{
        "format_code" => "pbb_ecp_payment",
        "our_account_no" => "3999999999",
        "params" => %{}
      })

    ps =
      for amt <- ["100.00", "200.50", "300.00"] do
        c =
          bank_contact_fixture(company, admin, %{
            "bank_code" => "PBBEMYKL",
            "bank_account_no" => "3123456789"
          })

        bank_payment_fixture(company, admin, c, bank, amt)
      end

    {:ok, [batch]} =
      BankPayment.create_batches(
        profile.id,
        Enum.map(ps, & &1.id),
        BankPayment.today(company),
        company,
        admin, force: true)

    lines = BankPayment.batch_lines(batch.id, company)
    %{admin: admin, company: company, profile: profile, batch: batch, lines: lines}
  end

  defp rec(l), do: String.pad_leading("#{l.record_no}", 12, "0")
  defp cents(l), do: l.amount |> Decimal.mult(100) |> Decimal.to_integer()

  test "parses PSF fixed positions" do
    {:ok, %{"spec" => %{"result" => r}}} = BankPayment.load_template("pbb_ecp_payment")
    assert Result.validate(r) == []
    text = psf_text("3999999999PM13102601", [{"000000000007", 12_050, "02", "INVALID ACCOUNT"}])
    assert {:ok, %{filename: "3999999999PM13102601", lines: [l]}} = Result.parse(text, r)
    assert {l.record_no, l.status, l.success, l.reason} == {7, "02", false, "INVALID ACCOUNT"}
    assert Decimal.equal?(l.amount, Decimal.new("120.50"))
  end

  test "success, failure, unknown id and amount mismatch; then a no-op re-import", %{
    company: company,
    admin: admin,
    batch: batch,
    lines: [l1, l2, l3]
  } do
    text =
      psf_text(Path.rootname(batch.filename), [
        {rec(l1), cents(l1), "01", ""},
        {rec(l2), cents(l2), "02", "INVALID ACCOUNT"},
        {rec(l3), cents(l3) + 1, "01", ""},
        {"999999999999", 100, "01", ""}
      ])

    assert {:ok, report} = BankPayment.import_result(text, company, admin)
    assert report.paid == [l1.payment_no]
    assert report.rejected == [l2.payment_no]
    assert [mm] = report.mismatched
    assert mm =~ l3.payment_no
    assert report.unmatched == ["999999999999"]
    assert report.missing == [l3.payment_no]
    assert report.batch.status == "submitted"
    assert report.batch.result_imported_at

    [n1, n2, n3] = BankPayment.batch_lines(batch.id, company)
    assert {n1.status, n1.live} == {"paid", true}
    assert {n2.status, n2.live, n2.bank_reason} == {"rejected", false, "INVALID ACCOUNT"}
    assert n3.status == "pending"

    assert {:ok, again} = BankPayment.import_result(text, company, admin)
    assert again.paid == [] and again.rejected == [] and again.conflicts == []
  end

  test "a result contradicting a manual release is reported, not applied", %{
    company: company,
    admin: admin,
    batch: batch,
    lines: [l1, _, _]
  } do
    {:ok, _} = BankPayment.mark_submitted(batch.id, company, admin)
    {:ok, _} = BankPayment.release_line(l1.id, "bank phoned: wrong account", company, admin)
    text = psf_text(Path.rootname(batch.filename), [{rec(l1), cents(l1), "01", ""}])

    assert {:ok, report} = BankPayment.import_result(text, company, admin)
    assert [c] = report.conflicts
    assert c =~ l1.payment_no
    assert hd(BankPayment.batch_lines(batch.id, company)).status == "rejected"
  end

  test "all lines paid → completed", %{company: company, admin: admin, batch: batch, lines: lines} do
    text =
      psf_text(Path.rootname(batch.filename), Enum.map(lines, &{rec(&1), cents(&1), "01", ""}))

    assert {:ok, %{batch: %{status: "completed"}}} =
             BankPayment.import_result(text, company, admin)
  end

  test "an unknown file is refused", %{company: company, admin: admin} do
    assert {:error, msg} = BankPayment.import_result(psf_text("NOPE", []), company, admin)
    assert msg =~ "no batch"
  end
end
