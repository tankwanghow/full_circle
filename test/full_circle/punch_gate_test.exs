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

  test "create_device returns plaintext once and stores only the hash", %{
    admin: admin,
    company: company
  } do
    assert {:ok, {device, plain}} = PunchGate.create_device("Gate 1", company, admin)
    assert is_binary(plain) and byte_size(plain) >= 32
    assert device.token_hash == PunchGate.hash_token(plain)
    assert device.token_hash != plain
    assert device.name == "Gate 1"
    assert device.company_id == company.id
    assert device.paired_by_user_id == admin.id
    assert is_nil(device.revoked_at)
  end

  test "duplicate name in company is rejected", %{admin: admin, company: company} do
    assert {:ok, _} = PunchGate.create_device("Gate 1", company, admin)
    assert {:error, cs} = PunchGate.create_device("Gate 1", company, admin)
    assert %{name: _} = errors_on(cs)
  end

  test "revoke then lookup by token returns nil", %{admin: admin, company: company} do
    {:ok, {device, plain}} = PunchGate.create_device("Gate 1", company, admin)
    assert %PunchDevice{} = PunchGate.get_active_device_by_token(plain)
    assert {:ok, revoked} = PunchGate.revoke_device(device, company, admin)
    refute is_nil(revoked.revoked_at)
    assert is_nil(PunchGate.get_active_device_by_token(plain))
  end
end
