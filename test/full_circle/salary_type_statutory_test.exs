defmodule FullCircle.SalaryTypeStatutoryTest do
  use FullCircle.DataCase, async: false

  alias FullCircle.{HR, StatutoryConfig}
  alias FullCircle.HR.SalaryType

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  defp build_cs(attrs, com_id \\ Ecto.UUID.generate()) do
    SalaryType.changeset(
      %SalaryType{},
      Map.merge(
        %{"name" => "X", "type" => "Recording", "company_id" => com_id},
        attrs
      )
    )
  end

  test "accepts a valid statutory_code" do
    cs = build_cs(%{"statutory_code" => "epf_employer"})
    assert cs.valid?
    assert Ecto.Changeset.get_field(cs, :statutory_code) == "epf_employer"
  end

  test "accepts blank/nil statutory_code (non-statutory type)" do
    assert build_cs(%{"statutory_code" => ""}).valid?
    assert build_cs(%{}).valid?
  end

  test "rejects an unknown statutory_code" do
    cs = build_cs(%{"statutory_code" => "bogus"})
    refute cs.valid?
    assert %{statutory_code: _} = errors_on(cs)
  end

  test "accepts a novel code once a calc is saved for the company" do
    admin = user_fixture()
    com = company_fixture(admin, %{})

    {:ok, _} =
      StatutoryConfig.save_calc(
        %{code: "hrdf_levy", name: "HRDF", effective_from: ~D[2026-01-01], script: "result = 1"},
        com,
        admin
      )

    cs = build_cs(%{"statutory_code" => "hrdf_levy"}, com.id)
    assert cs.valid?
  end

  test "rejects code in neither legacy list nor registry" do
    admin = user_fixture()
    com = company_fixture(admin, %{})
    cs = build_cs(%{"statutory_code" => "totally_new"}, com.id)
    refute cs.valid?
    assert %{statutory_code: _} = errors_on(cs)
  end

  describe "cal_func validation" do
    test "accepts a legacy cal_func" do
      cs = build_cs(%{"cal_func" => "epf_employee"})
      assert cs.valid?
    end

    test "accepts blank/nil cal_func" do
      assert build_cs(%{"cal_func" => ""}).valid?
      assert Ecto.Changeset.get_field(build_cs(%{"cal_func" => ""}), :cal_func) == nil
    end

    test "rejects a typo'd cal_func" do
      cs = build_cs(%{"cal_func" => "socso_emplyee"})
      refute cs.valid?
      assert %{cal_func: _} = errors_on(cs)
    end

    test "accepts a company statutory_calc code" do
      admin = user_fixture()
      com = company_fixture(admin, %{})

      {:ok, _} =
        StatutoryConfig.save_calc(
          %{code: "hrdf_levy", name: "HRDF", effective_from: ~D[2026-01-01], script: "result = 1"},
          com,
          admin
        )

      assert build_cs(%{"cal_func" => "hrdf_levy"}, com.id).valid?
    end

    test "rejects a code unknown to both legacy and registry" do
      admin = user_fixture()
      com = company_fixture(admin, %{})
      cs = build_cs(%{"cal_func" => "totally_new"}, com.id)
      refute cs.valid?
      assert %{cal_func: _} = errors_on(cs)
    end
  end
end
