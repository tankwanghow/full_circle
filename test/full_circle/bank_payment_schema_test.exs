defmodule FullCircle.BankPaymentSchemaTest do
  use ExUnit.Case, async: true

  alias FullCircle.BankPayment.{BatchLine, Profile}

  test "params text round-trips, ignoring blanks and comments" do
    text = "corporate_id = 123456\n\n# note\ncorporate_name=FULL CIRCLE SDN BHD\n"
    params = Profile.parse_params(text)
    assert params == %{"corporate_id" => "123456", "corporate_name" => "FULL CIRCLE SDN BHD"}
    assert Profile.parse_params(Profile.params_text(params)) == params
  end

  test "a param named like a built-in variable is refused" do
    cs =
      Profile.changeset(%Profile{}, %{"params" => %{"bank_code" => "PBBEMYKL", "Bad Name" => "x"}})

    msgs =
      for {:params, {m, opts}} <- cs.errors,
          do: String.replace(m, "%{key}", to_string(opts[:key]))

    assert "bank_code is a built-in variable name" in msgs
    assert Enum.any?(msgs, &(&1 =~ "is not a valid name"))
  end

  test "batch line requires its snapshot fields" do
    cs = BatchLine.changeset(%BatchLine{}, %{})
    refute cs.valid?
    assert cs.errors[:payment_id]
    assert cs.errors[:bank_account_no]
  end
end
