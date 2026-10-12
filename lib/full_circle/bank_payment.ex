defmodule FullCircle.BankPayment do
  @moduledoc """
  Bank bulk payment files. See docs/superpowers/specs/2026-10-12-bank-bulk-payment-design.md.
  """

  alias FullCircle.FileSpec

  @sources ["payments"]
  @row_vars ~w(record_id payment_no doc_date amount bank_code account_no account_name contact_name reg_no email emails descriptions advice advice_text)
  @child_vars ~w(advice_doc_no advice_doc_date advice_amount)
  @header_vars ~w(our_account_no payment_date today company_name seq batch_no)

  def reserved_variables, do: @row_vars ++ @child_vars ++ @header_vars

  def spec_params(spec),
    do: spec |> Map.get("params", []) |> List.wrap() |> Enum.filter(&is_binary/1)

  def format_variables(spec), do: reserved_variables() ++ spec_params(spec)

  def validate_spec(spec), do: FileSpec.validate(spec, format_variables(spec), @sources)
end
