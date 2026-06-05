defmodule FullCircle.SalaryTypeStatutoryTest do
  use FullCircle.DataCase, async: true

  alias FullCircle.HR.SalaryType

  defp build_cs(attrs) do
    SalaryType.changeset(
      %SalaryType{},
      Map.merge(
        %{"name" => "X", "type" => "Recording", "company_id" => Ecto.UUID.generate()},
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
end
