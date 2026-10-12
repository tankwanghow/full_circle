defmodule FullCircle.BankPaymentTest do
  use FullCircle.DataCase

  alias FullCircle.BankPayment
  alias FullCircle.BankPayment.Profile

  import FullCircle.BillingFixtures
  import FullCircle.BankPaymentFixtures
  import Ecto.Query

  setup do
    billing_setup()
  end

  describe "templates" do
    test "both bundled templates load and validate" do
      assert [%{code: "pbb_ecp_payment"}, %{code: "rhb_bulk_pay"}] = BankPayment.templates()

      for code <- ["rhb_bulk_pay", "pbb_ecp_payment"] do
        assert {:ok, %{"spec" => spec}} = BankPayment.load_template(code)
        assert :ok = BankPayment.validate_spec(spec)
      end
    end

    test "unknown or unsafe template codes are refused" do
      assert {:error, _} = BankPayment.load_template("../../etc/passwd")
      assert {:error, _} = BankPayment.load_template("nope")
    end

    test "bank keys are validated" do
      {:ok, %{"spec" => spec}} = BankPayment.load_template("rhb_bulk_pay")

      assert {:error, msgs} =
               BankPayment.validate_spec(Map.put(spec, "our_account_no_digits", ["x"]))

      assert Enum.any?(msgs, &(&1 =~ "our_account_no_digits"))
    end
  end

  test "today/1 is the company's local date", %{company: company} do
    assert BankPayment.today(company) == DateTime.to_date(DateTime.now!(company.timezone))
  end

  describe "formats" do
    test "save, effective version by date, replace in place", %{company: company, admin: admin} do
      f = install_template!(company, admin, "rhb_bulk_pay")
      assert BankPayment.effective_format(company.id, "rhb_bulk_pay", ~D[2026-10-12]).id == f.id
      assert BankPayment.effective_format(company.id, "rhb_bulk_pay", ~D[2025-12-31]) == nil
      assert BankPayment.format_version_exists?(company.id, "rhb_bulk_pay", "2026-01-01")

      attrs = %{
        "code" => "rhb_bulk_pay",
        "name" => "Renamed",
        "effective_from" => "2026-01-01",
        "spec" => f.spec
      }

      assert {:error, cs} = BankPayment.save_format(attrs, company, admin)
      assert errors_on(cs).effective_from != []
      assert {:ok, f2} = BankPayment.save_format(attrs, company, admin, replace: true)
      assert {f2.id, f2.name} == {f.id, "Renamed"}
    end

    test "an invalid spec is refused", %{company: company, admin: admin} do
      attrs = %{
        "code" => "bad",
        "name" => "Bad",
        "effective_from" => "2026-01-01",
        "spec" => %{"renderer" => "text"}
      }

      assert {:error, cs} = BankPayment.save_format(attrs, company, admin)
      assert errors_on(cs).spec != []
    end
  end

  describe "profiles" do
    test "must point at a Bank-type account", %{company: company, admin: admin} do
      cash = FullCircle.BillPayFixtures.pay_funds_account_fixture(company, admin)

      assert {:error, cs} =
               BankPayment.save_profile(
                 %Profile{},
                 %{
                   "account_id" => cash.id,
                   "format_code" => "rhb_bulk_pay",
                   "our_account_no" => "1",
                   "start_date" => "2026-01-01"
                 },
                 company,
                 admin
               )

      assert "must be a Bank account of this company" in errors_on(cs).account_id
    end

    test "warnings list missing params and a wrong account length", %{
      company: company,
      admin: admin
    } do
      bank = bank_gl_account_fixture(company, admin)

      p =
        profile_fixture(company, admin, bank, %{
          "params" => %{"corporate_id" => "123456"},
          "our_account_no" => "123"
        })

      assert BankPayment.profile_warnings(p, company) == :no_format
      install_template!(company, admin, "rhb_bulk_pay")
      assert [w1, w2] = BankPayment.profile_warnings(p, company)
      assert w1 =~ "corporate_name"
      assert w2 =~ "14 digits"
      assert [%Profile{account_name: name}] = BankPayment.list_profiles(company)
      assert name == bank.name
    end

    test "only admins may configure", %{company: company, admin: admin} do
      mgr = FullCircle.UserAccountsFixtures.user_fixture()
      FullCircle.Sys.allow_user_to_access(company, mgr, "manager", admin)
      assert :not_authorise = BankPayment.save_profile(%Profile{}, %{}, company, mgr)
      assert :not_authorise = BankPayment.save_format(%{}, company, mgr)
    end
  end

  defp setup_bank(company, admin, format \\ "rhb_bulk_pay", attrs \\ %{}) do
    install_template!(company, admin, format)
    bank = bank_gl_account_fixture(company, admin)
    profile = profile_fixture(company, admin, bank, Map.merge(%{"format_code" => format}, attrs))
    %{bank: bank, profile: profile}
  end

  defp pb_bank(company, admin),
    do:
      setup_bank(company, admin, "pbb_ecp_payment", %{
        "our_account_no" => "3999999999",
        "params" => %{}
      })

  defp pb_contact(company, admin),
    do:
      bank_contact_fixture(company, admin, %{
        "bank_code" => "PBBEMYKL",
        "bank_account_no" => "3123456789"
      })

  describe "eligible_payments/2" do
    test "the account's payments since start date, unbatched; flags missing bank details", %{
      company: company,
      admin: admin
    } do
      %{bank: bank, profile: profile} = setup_bank(company, admin)
      with_bank = bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), bank)
      no_bank = bank_payment_fixture(company, admin, contact_fixture(company, admin), bank)
      other = FullCircle.BillPayFixtures.pay_funds_account_fixture(company, admin)

      _elsewhere =
        bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), other)

      rows = BankPayment.eligible_payments(profile, company)
      assert Enum.sort(Enum.map(rows, & &1.id)) == Enum.sort([with_bank.id, no_bank.id])
      assert Enum.find(rows, &(&1.id == with_bank.id)).has_bank
      assert Enum.find(rows, &(&1.id == with_bank.id)).recent_change
      refute Enum.find(rows, &(&1.id == no_bank.id)).has_bank

      {:ok, _} =
        BankPayment.save_profile(
          profile,
          %{"start_date" => Date.to_iso8601(Date.add(BankPayment.today(company), 1))},
          company,
          admin
        )

      assert BankPayment.eligible_payments(BankPayment.get_profile(profile.id, company), company) ==
               []
    end
  end

  describe "create_batches/6" do
    test "creates a batch, removes its payments from the list, renders the file", %{
      company: company,
      admin: admin
    } do
      %{bank: bank, profile: profile} = setup_bank(company, admin)

      p =
        bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), bank, "250.00")

      assert {:ok, [batch]} =
               BankPayment.create_batches(
                 profile.id,
                 [p.id],
                 BankPayment.today(company),
                 company,
                 admin
               )

      assert batch.count == 1
      assert Decimal.equal?(batch.total, Decimal.new("250.00"))
      assert batch.filename =~ ~r/^PAYMENT_123456_\d{8}_001\.CSV$/
      assert batch.spec["filename"]
      assert BankPayment.live_batch_filename(p.id) == batch.filename
      assert BankPayment.eligible_payments(profile, company) == []

      assert {:ok, [{name, text}]} = BankPayment.download_files([batch.id], nil, company, admin)
      assert name == batch.filename
      assert text =~ ",250.00,MBBEMYKL,"
    end

    test "pre-flight: no bank details, more than 2 decimals; nothing saved", %{
      company: company,
      admin: admin
    } do
      %{bank: bank, profile: profile} = setup_bank(company, admin)
      p1 = bank_payment_fixture(company, admin, contact_fixture(company, admin), bank)
      p2 = bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), bank)

      FullCircle.Repo.update_all(from(x in FullCircle.BillPay.Payment, where: x.id == ^p2.id),
        set: [funds_amount: Decimal.new("100.005")]
      )

      assert {:error, msgs} =
               BankPayment.create_batches(
                 profile.id,
                 [p1.id, p2.id],
                 BankPayment.today(company),
                 company,
                 admin
               )

      assert Enum.any?(msgs, &(&1 =~ p1.payment_no and &1 =~ "no bank details"))
      assert Enum.any?(msgs, &(&1 =~ p2.payment_no and &1 =~ "2 decimal"))
      assert BankPayment.list_batches(company) == []
    end

    test "payment date must be today .. today+59 (company-local)", %{
      company: company,
      admin: admin
    } do
      %{bank: bank, profile: profile} = setup_bank(company, admin)
      p = bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), bank)

      assert {:error, msg} =
               BankPayment.create_batches(
                 profile.id,
                 [p.id],
                 Date.add(BankPayment.today(company), 60),
                 company,
                 admin
               )

      assert msg =~ "payment date"
    end

    test "our account number length must suit the format", %{company: company, admin: admin} do
      %{bank: bank, profile: profile} =
        setup_bank(company, admin, "rhb_bulk_pay", %{"our_account_no" => "123"})

      p = bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), bank)

      assert {:error, msg} =
               BankPayment.create_batches(
                 profile.id,
                 [p.id],
                 BankPayment.today(company),
                 company,
                 admin
               )

      assert msg =~ "14 digits"
    end

    test "a payment cannot be batched twice", %{company: company, admin: admin} do
      %{bank: bank, profile: profile} = setup_bank(company, admin)
      p = bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), bank)

      {:ok, _} =
        BankPayment.create_batches(profile.id, [p.id], BankPayment.today(company), company, admin)

      assert {:error, [msg]} =
               BankPayment.create_batches(
                 profile.id,
                 [p.id],
                 BankPayment.today(company),
                 company,
                 admin
               )

      assert msg =~ "already in a bank batch"
    end

    test "duplicate warning: same supplier and amount, then Create anyway", %{
      company: company,
      admin: admin
    } do
      %{bank: bank, profile: profile} = setup_bank(company, admin)
      c = bank_contact_fixture(company, admin)
      p1 = bank_payment_fixture(company, admin, c, bank, "80.00")
      p2 = bank_payment_fixture(company, admin, c, bank, "80.00")

      {:ok, _} =
        BankPayment.create_batches(
          profile.id,
          [p1.id],
          BankPayment.today(company),
          company,
          admin
        )

      assert {:duplicates, [msg]} =
               BankPayment.create_batches(
                 profile.id,
                 [p2.id],
                 BankPayment.today(company),
                 company,
                 admin
               )

      assert msg =~ p1.payment_no

      assert {:ok, [_]} =
               BankPayment.create_batches(
                 profile.id,
                 [p2.id],
                 BankPayment.today(company),
                 company,
                 admin, force: true)
    end

    test "an open Payment form can't save a stale amount after batching", %{
      company: company,
      admin: admin
    } do
      %{bank: bank, profile: profile} = setup_bank(company, admin)
      p = bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), bank)
      stale = FullCircle.BillPay.get_payment!(p.id, company, admin)

      {:ok, [_]} =
        BankPayment.create_batches(profile.id, [p.id], BankPayment.today(company), company, admin)

      fresh = FullCircle.BillPay.get_payment!(p.id, company, admin)
      assert fresh.lock_version == stale.lock_version + 1
    end

    test "splits at max_rows with consecutive sequence numbers", %{company: company, admin: admin} do
      %{bank: bank, profile: profile} = pb_bank(company, admin)
      f = BankPayment.effective_format(company.id, "pbb_ecp_payment", BankPayment.today(company))

      {:ok, _} =
        BankPayment.save_format(
          %{
            "code" => f.code,
            "name" => f.name,
            "effective_from" => "2026-01-01",
            "spec" => Map.put(f.spec, "max_rows", 2)
          },
          company,
          admin, replace: true)

      ids =
        for _ <- 1..3,
            do: bank_payment_fixture(company, admin, pb_contact(company, admin), bank).id

      assert {:ok, [b1, b2]} =
               BankPayment.create_batches(
                 profile.id,
                 ids,
                 BankPayment.today(company),
                 company,
                 admin, force: true)

      assert {b1.count, b2.count} == {2, 1}
      assert {b1.seq, b2.seq} == {1, 2}
      assert b1.filename =~ ~r/^3999999999PM\d{6}01\.txt$/
      assert {:ok, [_, _]} = BankPayment.download_files([b1.id, b2.id], nil, company, admin)
    end

    test "managers may, clerks may not", %{company: company, admin: admin} do
      %{bank: bank, profile: profile} = setup_bank(company, admin)
      p = bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), bank)
      clerk = FullCircle.UserAccountsFixtures.user_fixture()
      FullCircle.Sys.allow_user_to_access(company, clerk, "clerk", admin)

      assert :not_authorise =
               BankPayment.create_batches(
                 profile.id,
                 [p.id],
                 BankPayment.today(company),
                 company,
                 clerk
               )
    end
  end

  describe "download_files/4" do
    test "second download needs a reason; each download is logged", %{
      company: company,
      admin: admin
    } do
      %{bank: bank, profile: profile} = setup_bank(company, admin)
      p = bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), bank)

      {:ok, [b]} =
        BankPayment.create_batches(profile.id, [p.id], BankPayment.today(company), company, admin)

      assert {:ok, [{_, first}]} = BankPayment.download_files([b.id], nil, company, admin)
      assert {:error, msg} = BankPayment.download_files([b.id], " ", company, admin)
      assert msg =~ "reason"

      assert {:ok, [{_, ^first}]} =
               BankPayment.download_files([b.id], "browser lost it", company, admin)

      assert [_, %{reason: "browser lost it"}] = BankPayment.downloads_by_batch([b.id])[b.id]
    end
  end

  test "preview renders an unsaved spec against eligible payments only", %{
    company: company,
    admin: admin
  } do
    %{bank: bank, profile: profile} = setup_bank(company, admin)
    bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), bank, "12.34")

    batched =
      bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), bank, "56.78")

    {:ok, _} =
      BankPayment.create_batches(
        profile.id,
        [batched.id],
        BankPayment.today(company),
        company,
        admin
      )

    {:ok, %{"spec" => spec}} = BankPayment.load_template("rhb_bulk_pay")
    assert {:ok, text} = BankPayment.preview(spec, profile, company)
    assert text =~ ",12.34,"
    refute text =~ ",56.78,"
  end
end
