defmodule FullCircle.BankPaymentLifecycleTest do
  use FullCircle.DataCase

  alias FullCircle.BankPayment

  import FullCircle.BillingFixtures
  import FullCircle.BankPaymentFixtures

  setup do
    %{admin: admin, company: company} = billing_setup()
    install_template!(company, admin, "rhb_bulk_pay")
    bank = bank_gl_account_fixture(company, admin)
    profile = profile_fixture(company, admin, bank)
    mgr = FullCircle.UserAccountsFixtures.user_fixture()
    FullCircle.Sys.allow_user_to_access(company, mgr, "manager", admin)
    %{admin: admin, company: company, bank: bank, profile: profile, mgr: mgr}
  end

  defp batch!(ctx, n \\ 1) do
    ps =
      for _ <- 1..n,
          do:
            bank_payment_fixture(
              ctx.company,
              ctx.admin,
              bank_contact_fixture(ctx.company, ctx.admin),
              ctx.bank
            )

    {:ok, [b]} =
      BankPayment.create_batches(
        ctx.profile.id,
        Enum.map(ps, & &1.id),
        BankPayment.today(ctx.company),
        ctx.company,
        ctx.admin,
        force: true
      )

    {b, ps}
  end

  test "void an exported batch frees its payments; voided batches can't be downloaded; seq moves on",
       ctx do
    {b1, [p]} = batch!(ctx)
    assert {:error, _} = BankPayment.void_batch(b1.id, " ", ctx.company, ctx.mgr)

    assert {:ok, %{status: "voided"}} =
             BankPayment.void_batch(b1.id, "never uploaded", ctx.company, ctx.mgr)

    assert BankPayment.live_batch_filename(p.id) == nil
    assert {:error, msg} = BankPayment.download_files([b1.id], "x", ctx.company, ctx.admin)
    assert msg =~ "voided"

    {:ok, [b2]} =
      BankPayment.create_batches(
        ctx.profile.id,
        [p.id],
        BankPayment.today(ctx.company),
        ctx.company,
        ctx.admin
      )

    assert b2.seq == 2
    [l1] = BankPayment.batch_lines(b1.id, ctx.company)
    [l2] = BankPayment.batch_lines(b2.id, ctx.company)
    refute l1.record_no == l2.record_no
  end

  test "a submitted batch: only an admin may void it or download it again", ctx do
    {b, _} = batch!(ctx)
    {:ok, _} = BankPayment.download_files([b.id], nil, ctx.company, ctx.mgr)
    assert {:ok, %{status: "submitted"}} = BankPayment.mark_submitted(b.id, ctx.company, ctx.mgr)
    assert {:error, _} = BankPayment.mark_submitted(b.id, ctx.company, ctx.mgr)

    assert {:error, msg} = BankPayment.void_batch(b.id, "oops", ctx.company, ctx.mgr)
    assert msg =~ "only an admin"
    assert {:error, msg} = BankPayment.download_files([b.id], "again", ctx.company, ctx.mgr)
    assert msg =~ "only an admin"
    assert {:ok, _} = BankPayment.download_files([b.id], "again", ctx.company, ctx.admin)

    assert {:ok, %{status: "voided"}} =
             BankPayment.void_batch(b.id, "bank rejected the file", ctx.company, ctx.admin)
  end

  test "release one rejected line; the rest stay locked; returning a paid line is admin only",
       ctx do
    {b, [p1, p2]} = batch!(ctx, 2)
    {:ok, _} = BankPayment.mark_submitted(b.id, ctx.company, ctx.mgr)
    [l1, l2] = BankPayment.batch_lines(b.id, ctx.company)

    assert {:ok, %{status: "rejected", live: false}} =
             BankPayment.release_line(l1.id, "wrong account no", ctx.company, ctx.mgr)

    released = if l1.payment_id == p1.id, do: p1, else: p2
    kept = if released == p1, do: p2, else: p1
    assert BankPayment.live_batch_filename(released.id) == nil
    assert BankPayment.live_batch_filename(kept.id) == b.filename

    assert [%{last_reason: "wrong account no"}] =
             BankPayment.eligible_payments(ctx.profile, ctx.company)

    assert {:error, _} = BankPayment.return_line(l2.id, "returned", ctx.company, ctx.admin)
    # Simulate a bank result that paid l2 (Task 13 does this for real).
    FullCircle.Repo.update!(
      FullCircle.BankPayment.BatchLine.resolve_changeset(l2, %{status: "paid"})
    )

    FullCircle.Repo.update!(
      FullCircle.BankPayment.Batch.status_changeset(FullCircle.Repo.reload!(b), "partly_rejected")
    )

    assert :not_authorise = BankPayment.return_line(l2.id, "returned", ctx.company, ctx.mgr)

    assert {:ok, %{status: "rejected"}} =
             BankPayment.return_line(l2.id, "returned by receiving bank", ctx.company, ctx.admin)
  end

  test "a batch with a bank result can't be voided", ctx do
    {b, _} = batch!(ctx)
    FullCircle.Repo.update!(FullCircle.BankPayment.Batch.status_changeset(b, "completed"))
    assert {:error, msg} = BankPayment.void_batch(b.id, "x", ctx.company, ctx.admin)
    assert msg =~ "bank result"
  end

  test "paid outside file: leaves the list, can't be batched, undo brings it back", ctx do
    p =
      bank_payment_fixture(
        ctx.company,
        ctx.admin,
        bank_contact_fixture(ctx.company, ctx.admin),
        ctx.bank
      )

    assert {:ok, _} =
             BankPayment.dismiss_payment(p.id, "paid by cheque 1234", ctx.company, ctx.mgr)

    assert BankPayment.eligible_payments(ctx.profile, ctx.company) == []

    assert [%{payment_no: no, note: "paid by cheque 1234"}] =
             BankPayment.list_dismissed(ctx.company)

    assert no == p.payment_no

    assert {:error, [msg]} =
             BankPayment.create_batches(
               ctx.profile.id,
               [p.id],
               BankPayment.today(ctx.company),
               ctx.company,
               ctx.admin
             )

    assert msg =~ "paid outside file"

    assert {:ok, _} = BankPayment.undismiss_payment(p.id, ctx.company, ctx.mgr)
    assert [_] = BankPayment.eligible_payments(ctx.profile, ctx.company)
  end

  test "a batched payment can't be dismissed", ctx do
    {_b, [p]} = batch!(ctx)
    assert {:error, msg} = BankPayment.dismiss_payment(p.id, nil, ctx.company, ctx.mgr)
    assert msg =~ "bank batch"
  end

  test "locked fields refused while a line is live; other edits pass; release unlocks", ctx do
    {b, [p]} = batch!(ctx)

    assert :ok =
             BankPayment.assert_payment_unlocked(p, Ecto.Changeset.change(p, descriptions: "x"))

    assert {:error, :bank_batched, name} =
             BankPayment.assert_payment_unlocked(
               p,
               Ecto.Changeset.change(p, funds_amount: Decimal.new("1"))
             )

    assert name == b.filename

    fresh = FullCircle.BillPay.get_payment!(p.id, ctx.company, ctx.admin)

    assert {:error, :bank_batched, ^name} =
             FullCircle.BillPay.update_payment(
               fresh,
               %{"funds_amount" => "1.00", "payment_no" => fresh.payment_no},
               ctx.company,
               ctx.admin
             )

    {:ok, _} = BankPayment.void_batch(b.id, "redo", ctx.company, ctx.admin)

    assert :ok =
             BankPayment.assert_payment_unlocked(
               p,
               Ecto.Changeset.change(p, funds_amount: Decimal.new("1"))
             )
  end
end
