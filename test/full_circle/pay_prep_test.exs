defmodule FullCircle.PayPrepTest do
  use FullCircle.DataCase, async: true

  alias FullCircle.HR.PayPrep

  defp base(attrs) do
    PayPrep.changeset(%PayPrep{}, Map.merge(%{
      "company_id" => Ecto.UUID.generate(),
      "employee_id" => Ecto.UUID.generate(),
      "pay_month" => 5,
      "pay_year" => 2026
    }, attrs))
  end

  test "valid without verification" do
    assert base(%{}).valid?
  end

  test "verified=true requires a funds_account_id" do
    refute base(%{"verified" => true}).valid?
    assert base(%{"verified" => true, "funds_account_id" => Ecto.UUID.generate()}).valid?
  end

  test "requires period and scope" do
    refute PayPrep.changeset(%PayPrep{}, %{}).valid?
  end

  describe "pay_prep context" do
    import FullCircle.SysFixtures
    import FullCircle.UserAccountsFixtures
    import FullCircle.HRFixtures
    import FullCircle.AccountingFixtures
    alias FullCircle.HR

    setup do
      admin = user_fixture()
      com = company_fixture(admin, %{})
      emp = employee_fixture(%{}, com, admin)
      acct = account_fixture(%{}, com, admin)
      %{admin: admin, com: com, emp: emp, acct: acct}
    end

    test "get_or_init returns an unsaved struct when none exists", %{com: com, emp: emp} do
      pp = HR.get_or_init_pay_prep(emp.id, 5, 2026, com)
      assert pp.pay_month == 5 and pp.pay_year == 2026
      assert is_nil(pp.id)
      refute pp.verified
    end

    test "set account persists and round-trips", %{com: com, emp: emp, admin: admin, acct: acct} do
      {:ok, pp} = HR.set_pay_prep_account(emp.id, 5, 2026, acct.id, com, admin)
      assert pp.id
      assert HR.get_or_init_pay_prep(emp.id, 5, 2026, com).funds_account_id == pp.funds_account_id
    end

    test "set verified records audit; clear unsets", %{com: com, emp: emp, admin: admin, acct: acct} do
      {:ok, _} = HR.set_pay_prep_account(emp.id, 5, 2026, acct.id, com, admin)
      {:ok, pp} = HR.set_pay_prep_verified(emp.id, 5, 2026, true, com, admin)
      assert pp.verified and pp.verified_by_id == admin.id and pp.verified_at

      HR.clear_pay_prep(com, emp.id, 5, 2026)
      refute HR.get_or_init_pay_prep(emp.id, 5, 2026, com).verified
    end
  end
end
