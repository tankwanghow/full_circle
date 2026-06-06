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
end
