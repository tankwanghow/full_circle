defmodule FullCircle.PeriodLockTest do
  use FullCircle.DataCase

  alias FullCircle.Sys
  alias FullCircle.Sys.Company

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  defp company_today(company) do
    case DateTime.now(company.timezone || "Etc/UTC") do
      {:ok, dt} -> DateTime.to_date(dt)
      _ -> Date.utc_today()
    end
  end

  describe "period cutoff storage" do
    setup do
      admin = user_fixture()
      company = company_fixture(admin, %{})
      %{admin: admin, company: company}
    end

    test "no cutoff by default", %{company: company} do
      assert Sys.period_closed_through(company) == nil
    end

    test "an admin can close a period", %{company: company, admin: admin} do
      assert {:ok, company} = Sys.close_period_through(company, ~D[2025-12-31], admin)
      assert Sys.period_closed_through(company) == ~D[2025-12-31]
    end

    test "a non-admin cannot close a period", %{company: company, admin: admin} do
      clerk = user_fixture()
      {:ok, _} = Sys.allow_user_to_access(company, clerk, "clerk", admin)

      assert :not_authorise = Sys.close_period_through(company, ~D[2025-12-31], clerk)
      assert Sys.period_closed_through(company) == nil
    end

    test "a future date is rejected", %{company: company, admin: admin} do
      future = Date.add(company_today(company), 1)
      assert {:error, :future_date} = Sys.close_period_through(company, future, admin)
      assert Sys.period_closed_through(company) == nil
    end

    test "nil clears the cutoff", %{company: company, admin: admin} do
      {:ok, company} = Sys.close_period_through(company, ~D[2025-12-31], admin)
      assert {:ok, company} = Sys.close_period_through(company, nil, admin)
      assert Sys.period_closed_through(company) == nil
    end

    test "closing and reopening are both logged", %{company: company, admin: admin} do
      {:ok, company} = Sys.close_period_through(company, ~D[2025-12-31], admin)
      {:ok, company} = Sys.close_period_through(company, ~D[2025-06-30], admin)

      logs =
        Repo.all(
          from l in FullCircle.Sys.Log,
            where: l.company_id == ^company.id and l.action == "close_period"
        )

      assert length(logs) == 2
      assert Enum.any?(logs, &(&1.delta =~ "2025-12-31"))
      assert Enum.any?(logs, &(&1.delta =~ "2025-06-30"))
    end

    test "a malformed stored value reads as no cutoff", %{company: company} do
      {:ok, _} = Sys.update_company_settings(company, "period", %{"closed_through" => "rubbish"})
      assert Sys.period_closed_through(company) == nil
    end

    test "reads the cutoff from the database, not the in-memory struct", %{
      company: company,
      admin: admin
    } do
      {:ok, _} = Sys.close_period_through(company, ~D[2025-12-31], admin)
      stale = %{company | settings: %{}}
      assert Sys.period_closed_through(stale) == ~D[2025-12-31]
    end
  end

  describe "assert_period_open/2" do
    setup do
      admin = user_fixture()
      company = company_fixture(admin, %{})
      {:ok, company} = Sys.close_period_through(company, ~D[2025-12-31], admin)
      %{admin: admin, company: company}
    end

    test "a date on the cutoff is closed", %{company: company} do
      assert {:error, :period_closed} =
               FullCircle.Accounting.assert_period_open([~D[2025-12-31]], company)
    end

    test "a date before the cutoff is closed", %{company: company} do
      assert {:error, :period_closed} =
               FullCircle.Accounting.assert_period_open([~D[2025-11-04]], company)
    end

    test "the day after the cutoff is open", %{company: company} do
      assert :ok = FullCircle.Accounting.assert_period_open([~D[2026-01-01]], company)
    end

    test "any closed date in the list closes the write", %{company: company} do
      assert {:error, :period_closed} =
               FullCircle.Accounting.assert_period_open([~D[2026-01-01], ~D[2025-11-04]], company)
    end

    test "nils are ignored", %{company: company} do
      assert :ok = FullCircle.Accounting.assert_period_open([nil], company)
      assert :ok = FullCircle.Accounting.assert_period_open([], company)
    end

    test "no cutoff means everything is open", %{admin: admin} do
      open_company = company_fixture(admin, %{})
      assert :ok = FullCircle.Accounting.assert_period_open([~D[2019-01-01]], open_company)
    end
  end

  describe "map_period_closed/1" do
    test "collapses the Multi 4-tuple" do
      assert {:error, :period_closed} =
               FullCircle.Accounting.map_period_closed(
                 {:error, :assert_period_open, :period_closed, %{}}
               )
    end

    test "passes other results through" do
      assert {:ok, :x} = FullCircle.Accounting.map_period_closed({:ok, :x})
      assert :not_authorise = FullCircle.Accounting.map_period_closed(:not_authorise)
    end
  end

  describe "Invoice under a closed period" do
    setup do
      %{admin: admin, company: company} = FullCircle.BillingFixtures.billing_setup()
      %{admin: admin, company: company}
    end

    test "creating into a closed period is rejected", %{company: company, admin: admin} do
      {:ok, _} = Sys.close_period_through(company, Date.utc_today(), admin)

      assert {:error, :period_closed} =
               create_invoice_dated(company, admin, Date.utc_today())
    end

    test "creating after the cutoff succeeds", %{company: company, admin: admin} do
      {:ok, _} = Sys.close_period_through(company, Date.add(Date.utc_today(), -30), admin)

      assert {:ok, %{create_invoice: _}} =
               create_invoice_dated(company, admin, Date.utc_today())
    end

    test "editing a GL field on a closed-period invoice is rejected",
         %{company: company, admin: admin} do
      invoice = FullCircle.BillingFixtures.invoice_fixture(company, admin)
      {:ok, _} = Sys.close_period_through(company, Date.utc_today(), admin)

      invoice = FullCircle.Billing.get_invoice!(invoice.id, company, admin)

      assert {:error, :period_closed} =
               FullCircle.Billing.update_invoice(
                 invoice,
                 gl_changing_attrs(invoice),
                 company,
                 admin
               )
    end

    test "a description-only edit on a closed-period invoice still succeeds",
         %{company: company, admin: admin} do
      invoice = FullCircle.BillingFixtures.invoice_fixture(company, admin)
      {:ok, _} = Sys.close_period_through(company, Date.utc_today(), admin)

      invoice = FullCircle.Billing.get_invoice!(invoice.id, company, admin)

      assert {:ok, %{update_invoice: updated}} =
               FullCircle.Billing.update_invoice(
                 invoice,
                 description_only_attrs(invoice, "edited after closing"),
                 company,
                 admin
               )

      assert updated.descriptions == "edited after closing"
    end

    test "moving an open invoice into a closed period is rejected",
         %{company: company, admin: admin} do
      invoice = FullCircle.BillingFixtures.invoice_fixture(company, admin)
      {:ok, _} = Sys.close_period_through(company, Date.add(Date.utc_today(), -30), admin)

      invoice = FullCircle.Billing.get_invoice!(invoice.id, company, admin)

      assert {:error, :period_closed} =
               FullCircle.Billing.update_invoice(
                 invoice,
                 date_change_attrs(invoice, Date.add(Date.utc_today(), -60)),
                 company,
                 admin
               )
    end
  end

  describe "PurInvoice under a closed period" do
    setup do
      %{admin: admin, company: company} = FullCircle.BillingFixtures.billing_setup()
      %{admin: admin, company: company}
    end

    test "creating into a closed period is rejected", %{company: company, admin: admin} do
      {:ok, _} = Sys.close_period_through(company, Date.utc_today(), admin)

      assert {:error, :period_closed} =
               create_pur_invoice_dated(company, admin, Date.utc_today())
    end
  end

  defp invoice_to_attrs(invoice) do
    details =
      invoice.invoice_details
      |> Enum.with_index()
      |> Enum.into(%{}, fn {d, i} ->
        {to_string(i),
         %{
           "id" => d.id,
           "good_id" => d.good_id,
           "good_name" => d.good_name,
           "account_id" => d.account_id,
           "account_name" => d.account_name,
           "tax_code_id" => d.tax_code_id,
           "tax_code_name" => d.tax_code_name,
           "package_id" => d.package_id,
           "package_name" => d.package_name,
           "quantity" => to_string(d.quantity),
           "unit_price" => to_string(d.unit_price),
           "discount" => to_string(d.discount),
           "tax_rate" => to_string(d.tax_rate),
           "unit_multiplier" => "0",
           "_persistent_id" => to_string(i)
         }}
      end)

    %{
      "invoice_no" => invoice.invoice_no,
      "e_inv_internal_id" => invoice.e_inv_internal_id,
      "invoice_date" => Date.to_string(invoice.invoice_date),
      "due_date" => Date.to_string(invoice.due_date),
      "contact_name" => invoice.contact_name,
      "contact_id" => invoice.contact_id,
      "descriptions" => invoice.descriptions,
      "lock_version" => invoice.lock_version,
      "invoice_details" => details
    }
  end

  defp description_only_attrs(invoice, text) do
    invoice |> invoice_to_attrs() |> Map.put("descriptions", text)
  end

  defp gl_changing_attrs(invoice) do
    attrs = invoice_to_attrs(invoice)
    details = Map.update!(attrs["invoice_details"], "0", &Map.put(&1, "unit_price", "99.00"))
    Map.put(attrs, "invoice_details", details)
  end

  defp date_change_attrs(invoice, date) do
    invoice |> invoice_to_attrs() |> Map.put("invoice_date", Date.to_string(date))
  end

  defp create_invoice_dated(company, user, date) do
    contact = FullCircle.BillingFixtures.contact_fixture(company, user)
    good = FullCircle.BillingFixtures.good_fixture(company, user)
    acct = FullCircle.Accounting.get_account_by_name("General Sales", company, user)

    tc =
      Repo.one!(
        from t in FullCircle.Accounting.TaxCode,
          where: t.company_id == ^company.id and t.code == "NoSTax"
      )

    attrs =
      FullCircle.BillingFixtures.invoice_attrs(contact, good, acct, tc, tax_rate: "0")
      |> Map.put("invoice_date", Date.to_string(date))

    FullCircle.Billing.create_invoice(attrs, company, user)
  end

  defp create_pur_invoice_dated(company, user, date) do
    contact = FullCircle.BillingFixtures.contact_fixture(company, user)
    good = FullCircle.BillingFixtures.good_fixture(company, user)
    acct = FullCircle.Accounting.get_account_by_name("General Purchases", company, user)

    tc =
      Repo.one!(
        from t in FullCircle.Accounting.TaxCode,
          where: t.company_id == ^company.id and t.code == "NoPTax"
      )

    attrs =
      FullCircle.BillingFixtures.pur_invoice_attrs(contact, good, acct, tc, tax_rate: "0")
      |> Map.put("pur_invoice_date", Date.to_string(date))

    FullCircle.Billing.create_pur_invoice(attrs, company, user)
  end

  describe "CreditNote under a closed period" do
    setup do
      %{admin: admin, company: company} = FullCircle.BillingFixtures.billing_setup()
      %{admin: admin, company: company}
    end

    test "creating into a closed period is rejected", %{company: company, admin: admin} do
      {:ok, _} = Sys.close_period_through(company, Date.utc_today(), admin)

      assert {:error, :period_closed} =
               FullCircle.DebCre.create_credit_note(
                 credit_note_attrs_dated(company, admin, Date.utc_today()),
                 company,
                 admin
               )
    end

    test "a description-only edit on a closed-period credit note still succeeds",
         %{company: company, admin: admin} do
      {:ok, %{create_credit_note: cn}} =
        FullCircle.DebCre.create_credit_note(
          credit_note_attrs_dated(company, admin, Date.utc_today()),
          company,
          admin
        )

      {:ok, _} = Sys.close_period_through(company, Date.utc_today(), admin)
      cn = FullCircle.DebCre.get_credit_note!(cn.id, company, admin)

      # CreditNote has no header descriptions field; details.descriptions is
      # non-GL (fingerprint ignores particulars).
      attrs =
        cn
        |> credit_note_to_attrs()
        |> put_in(["credit_note_details", "0", "descriptions"], "edited after closing")

      assert {:ok, _} = FullCircle.DebCre.update_credit_note(cn, attrs, company, admin)
    end
  end

  describe "DebitNote under a closed period" do
    setup do
      %{admin: admin, company: company} = FullCircle.BillingFixtures.billing_setup()
      %{admin: admin, company: company}
    end

    test "creating into a closed period is rejected", %{company: company, admin: admin} do
      {:ok, _} = Sys.close_period_through(company, Date.utc_today(), admin)

      assert {:error, :period_closed} =
               FullCircle.DebCre.create_debit_note(
                 debit_note_attrs_dated(company, admin, Date.utc_today()),
                 company,
                 admin
               )
    end
  end

  defp credit_note_to_attrs(cn) do
    details =
      cn.credit_note_details
      |> Enum.with_index()
      |> Enum.into(%{}, fn {d, i} ->
        {to_string(i),
         %{
           "id" => d.id,
           "descriptions" => d.descriptions,
           "account_id" => d.account_id,
           "account_name" => d.account_name,
           "tax_code_id" => d.tax_code_id,
           "tax_code_name" => d.tax_code_name,
           "quantity" => to_string(d.quantity),
           "unit_price" => to_string(d.unit_price),
           "tax_rate" => to_string(d.tax_rate),
           "_persistent_id" => to_string(i)
         }}
      end)

    %{
      "note_no" => cn.note_no,
      "note_date" => Date.to_string(cn.note_date),
      "contact_name" => cn.contact_name,
      "contact_id" => cn.contact_id,
      "e_inv_internal_id" => cn.e_inv_internal_id,
      "lock_version" => cn.lock_version,
      "credit_note_details" => details,
      "transaction_matchers" => %{}
    }
  end

  defp credit_note_attrs_dated(company, user, date) do
    contact = FullCircle.BillingFixtures.contact_fixture(company, user)
    acct = FullCircle.Accounting.get_account_by_name("General Sales", company, user)

    tc =
      Repo.one!(
        from t in FullCircle.Accounting.TaxCode,
          where: t.company_id == ^company.id and t.code == "NoSTax"
      )

    FullCircle.DebCreFixtures.credit_note_attrs(contact, acct, tc, tax_rate: "0")
    |> Map.put("note_date", Date.to_string(date))
  end

  defp debit_note_attrs_dated(company, user, date) do
    contact = FullCircle.BillingFixtures.contact_fixture(company, user)
    acct = FullCircle.Accounting.get_account_by_name("General Purchases", company, user)

    tc =
      Repo.one!(
        from t in FullCircle.Accounting.TaxCode,
          where: t.company_id == ^company.id and t.code == "NoPTax"
      )

    FullCircle.DebCreFixtures.debit_note_attrs(contact, acct, tc, tax_rate: "0")
    |> Map.put("note_date", Date.to_string(date))
  end

  describe "Payment under a closed period" do
    setup do
      %{admin: admin, company: company} = FullCircle.BillingFixtures.billing_setup()
      %{admin: admin, company: company}
    end

    test "creating into a closed period is rejected", %{company: company, admin: admin} do
      {:ok, _} = Sys.close_period_through(company, Date.utc_today(), admin)

      assert {:error, :period_closed} =
               FullCircle.BillPay.create_payment(
                 payment_attrs_dated(company, admin, Date.utc_today()),
                 company,
                 admin
               )
    end

    test "creating after the cutoff succeeds", %{company: company, admin: admin} do
      {:ok, _} = Sys.close_period_through(company, Date.add(Date.utc_today(), -30), admin)

      assert {:ok, %{create_payment: _}} =
               FullCircle.BillPay.create_payment(
                 payment_attrs_dated(company, admin, Date.utc_today()),
                 company,
                 admin
               )
    end
  end

  defp payment_attrs_dated(company, user, date) do
    contact = FullCircle.BillingFixtures.contact_fixture(company, user)
    good = FullCircle.BillingFixtures.good_fixture(company, user)
    pur_acct = FullCircle.Accounting.get_account_by_name("General Purchases", company, user)
    funds_acct = FullCircle.BillPayFixtures.pay_funds_account_fixture(company, user)

    tc =
      Repo.one!(
        from t in FullCircle.Accounting.TaxCode,
          where: t.company_id == ^company.id and t.code == "NoPTax"
      )

    FullCircle.BillPayFixtures.payment_attrs(contact, good, pur_acct, tc, funds_acct,
      tax_rate: "0"
    )
    |> Map.put("payment_date", Date.to_string(date))
  end
end
