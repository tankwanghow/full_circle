defmodule FullCircle.BankPaymentReviewFixesTest do
  use FullCircle.DataCase

  alias FullCircle.BankPayment

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
      for amt <- ["100.00", "200.00"] do
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
        admin,
        force: true
      )

    %{
      admin: admin,
      company: company,
      batch: batch,
      lines: BankPayment.batch_lines(batch.id, company)
    }
  end

  defp rec(l), do: String.pad_leading("#{l.record_no}", 12, "0")
  defp cents(l), do: l.amount |> Decimal.mult(100) |> Decimal.to_integer()
  defp psf(batch, rows), do: psf_text(Path.rootname(batch.filename), rows)

  test "a batch with a partial bank result can't be voided, and paid lines stay live", ctx do
    [l1, _l2] = ctx.lines

    {:ok, report} =
      BankPayment.import_result(
        psf(ctx.batch, [{rec(l1), cents(l1), "01", ""}]),
        ctx.company,
        ctx.admin
      )

    assert report.batch.status == "submitted"

    assert {:error, msg} = BankPayment.void_batch(ctx.batch.id, "oops", ctx.company, ctx.admin)
    assert msg =~ "bank result"
    assert BankPayment.live_batch_filename(l1.payment_id) == ctx.batch.filename
  end

  test "an unrecognised status code changes nothing and is reported", ctx do
    [l1, _] = ctx.lines

    {:ok, report} =
      BankPayment.import_result(
        psf(ctx.batch, [{rec(l1), cents(l1), "  ", ""}]),
        ctx.company,
        ctx.admin
      )

    assert [u] = report.unrecognised
    assert u =~ l1.payment_no
    assert hd(BankPayment.batch_lines(ctx.batch.id, ctx.company)).status == "pending"
  end

  test "a record id repeated in one file is reported and never flips a paid line", ctx do
    [l1, _] = ctx.lines

    text =
      psf(ctx.batch, [
        {rec(l1), cents(l1), "01", ""},
        {rec(l1), cents(l1), "02", "INVALID ACCOUNT"}
      ])

    {:ok, report} = BankPayment.import_result(text, ctx.company, ctx.admin)
    assert report.paid == [l1.payment_no]
    assert report.rejected == []
    assert Enum.any?(report.conflicts, &(&1 =~ "twice"))
    assert hd(BankPayment.batch_lines(ctx.batch.id, ctx.company)).status == "paid"
  end

  test "a garbled amount is reported, not a crash", ctx do
    [l1, _] = ctx.lines

    text =
      psf(ctx.batch, [{rec(l1), cents(l1), "01", ""}])
      |> String.replace("000000000000010000", "0000000000000100.0")

    assert {:ok, report} = BankPayment.import_result(text, ctx.company, ctx.admin)
    assert [m] = report.mismatched
    assert m =~ l1.payment_no
  end

  test "a computed column may not shadow a built-in variable" do
    {:ok, %{"spec" => spec}} = BankPayment.load_template("pbb_ecp_payment")
    spec = put_in(spec, ["computed", "amount"], "amount * 2")
    assert {:error, msgs} = BankPayment.validate_spec(spec)
    assert Enum.any?(msgs, &(&1 =~ "computed amount"))
  end

  test "the result spec must list failure codes" do
    {:ok, %{"spec" => spec}} = BankPayment.load_template("pbb_ecp_payment")

    assert {:error, msgs} =
             BankPayment.validate_spec(update_in(spec, ["result"], &Map.delete(&1, "failure")))

    assert Enum.any?(msgs, &(&1 =~ "failure"))
  end
end
