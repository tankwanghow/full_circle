defmodule FullCircle.BankPaymentBackfillTest do
  use FullCircle.DataCase

  alias FullCircle.{BankPayment, Repo, StdInterface}
  alias FullCircle.Accounting.{Account, Contact}
  alias FullCircle.BankPayment.Backfill

  import FullCircle.BillingFixtures
  import FullCircle.BankPaymentFixtures
  import Ecto.Query

  @rhb "Rhb Bank 2-08025-0001399-9"
  @pbb "Public Bank 3126284617"

  setup do
    %{admin: admin, company: company} = billing_setup()

    accounts =
      for name <- [@rhb, @pbb], into: %{} do
        {:ok, a} =
          StdInterface.create(
            Account,
            "account",
            %{"name" => name, "account_type" => "Bank", "descriptions" => "bank"},
            company,
            admin
          )

        {name, a}
      end

    %{admin: admin, company: company, accounts: accounts}
  end

  # A Payment from `account` to `contact`, dated `days_ago`, with `desc` as its description.
  defp pay(ctx, contact, account, desc, days_ago \\ 1) do
    p = bank_payment_fixture(ctx.company, ctx.admin, contact, ctx.accounts[account])

    Repo.update_all(from(x in FullCircle.BillPay.Payment, where: x.id == ^p.id),
      set: [descriptions: desc, payment_date: Date.add(Date.utc_today(), -days_ago)]
    )

    p
  end

  defp bank(c), do: Repo.get!(Contact, c.id) |> Map.take([:bank_code, :bank_account_no])

  defp scenario(ctx) do
    soon = contact_fixture(ctx.company, ctx.admin, %{"name" => "Soon Soon Oilmills"})
    pay(ctx, soon, @rhb, "IBG (MBB 507116409616)", 3)
    pay(ctx, soon, @pbb, "IBG(MBB 507116409616)", 2)

    yin = contact_fixture(ctx.company, ctx.admin, %{"name" => "Yin Feng"})
    pay(ctx, yin, @rhb, "TRANSFER (RHB 20806100058823)")

    # A newer but too-short RHB number is a typo; the valid one wins.
    free = contact_fixture(ctx.company, ctx.admin, %{"name" => "Freeway Frontier"})
    pay(ctx, free, @rhb, "TRANSFER (RHB 20809800039680)", 9)
    pay(ctx, free, @rhb, "TRANSFER (RHB 20809800039)", 1)

    cheque = contact_fixture(ctx.company, ctx.admin, %{"name" => "Teik Joo Chan"})
    pay(ctx, cheque, @rhb, "706257")

    jpj =
      contact_fixture(ctx.company, ctx.admin, %{"name" => "Jabatan Pengangkutan Jalan Malaysia"})

    pay(ctx, jpj, @pbb, "IBG PBB 3060376923 (CHAI KOK MUN)")

    hand =
      bank_contact_fixture(ctx.company, ctx.admin, %{
        "bank_code" => "CIBBMYKL",
        "bank_account_no" => "8004840594"
      })

    pay(ctx, hand, @rhb, "IBG (MBB 508047116608)")

    %{soon: soon, yin: yin, free: free, cheque: cheque, jpj: jpj, hand: hand}
  end

  test "a dry run reports and changes nothing", ctx do
    s = scenario(ctx)
    assert {:ok, r} = Backfill.run(ctx.company.id, ctx.admin.email)
    assert r.dry_run
    assert r.formats_created == ["pbb_ecp_payment", "rhb_bulk_pay"]
    assert r.profiles_created == [@pbb, @rhb]

    assert Enum.map(r.imported, & &1.contact) == [
             "Freeway Frontier",
             "Soon Soon Oilmills",
             "Yin Feng"
           ]

    assert BankPayment.list_formats(ctx.company.id) == []
    assert BankPayment.list_profiles(ctx.company) == []
    assert bank(s.soon) == %{bank_code: nil, bank_account_no: nil}
  end

  test "a real run sets up formats and profiles and imports bank details", ctx do
    s = scenario(ctx)
    assert {:ok, r} = Backfill.run(ctx.company.id, ctx.admin.email, dry_run: false)
    refute r.dry_run

    assert [
             %{format_code: "pbb_ecp_payment", our_account_no: "3126284617"},
             %{format_code: "rhb_bulk_pay", our_account_no: "20802500013999", params: params}
           ] =
             BankPayment.list_profiles(ctx.company) |> Enum.sort_by(& &1.format_code)

    assert params == %{"corporate_name" => ctx.company.name}
    assert r.profile_warnings[@rhb] == ["missing param: corporate_id"]

    assert bank(s.soon) == %{bank_code: "MBBEMYKL", bank_account_no: "507116409616"}
    assert bank(s.yin) == %{bank_code: "RHBBMYKL", bank_account_no: "20806100058823"}
    assert bank(s.free) == %{bank_code: "RHBBMYKL", bank_account_no: "20809800039680"}
    assert bank(s.cheque) == %{bank_code: nil, bank_account_no: nil}
    assert bank(s.jpj) == %{bank_code: nil, bank_account_no: nil}
    assert bank(s.hand) == %{bank_code: "CIBBMYKL", bank_account_no: "8004840594"}

    assert "Jabatan Pengangkutan Jalan Malaysia" in r.skipped
    assert s.hand.name in r.kept_existing
    assert [%{contact: "Freeway Frontier"}] = r.ambiguous
  end

  test "running again changes nothing", ctx do
    scenario(ctx)
    {:ok, _} = Backfill.run(ctx.company.id, ctx.admin.email, dry_run: false)
    assert {:ok, r} = Backfill.run(ctx.company.id, ctx.admin.email, dry_run: false)
    assert r.formats_created == []
    assert r.profiles_created == []
    assert r.imported == []
  end

  test "only an admin of the company may run it", ctx do
    clerk = FullCircle.UserAccountsFixtures.user_fixture()
    FullCircle.Sys.allow_user_to_access(ctx.company, clerk, "clerk", ctx.admin)
    assert {:error, msg} = Backfill.run(ctx.company.id, clerk.email)
    assert msg =~ "admin"
    assert {:error, _} = Backfill.run(ctx.company.id, "nobody@example.com")
  end

  test "report/1 prints a readable summary", ctx do
    scenario(ctx)
    {:ok, r} = Backfill.run(ctx.company.id, ctx.admin.email)
    text = Backfill.report(r)
    assert text =~ "DRY RUN"
    assert text =~ "would import 3"
    assert text =~ "Soon Soon Oilmills"
  end
end
