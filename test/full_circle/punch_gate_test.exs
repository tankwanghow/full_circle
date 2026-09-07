defmodule FullCircle.PunchGateTest do
  use FullCircle.DataCase

  alias FullCircle.PunchGate
  alias FullCircle.PunchGate.PunchDevice

  import FullCircle.UserAccountsFixtures
  import FullCircle.SysFixtures

  setup do
    admin = user_fixture()
    company = company_fixture(admin, %{})
    %{admin: admin, company: company}
  end

  test "PunchDevice schema fields exist" do
    assert %PunchDevice{}.__struct__ == PunchDevice
    assert :name in PunchDevice.__schema__(:fields)
    assert :token_hash in PunchDevice.__schema__(:fields)
    assert :revoked_at in PunchDevice.__schema__(:fields)
  end
end
