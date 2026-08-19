defmodule FullCircle.XeroImport.Client do
  @moduledoc false

  @type client :: term()
  @type result :: {:ok, term()} | {:error, term()}

  @callback get_organisation(client()) :: result()
  @callback list_accounts(client()) :: result()
  @callback list_tax_rates(client()) :: result()
  @callback list_contacts(client()) :: result()
  @callback list_items(client()) :: result()
  @callback list_invoices(client()) :: result()
  @callback list_credit_notes(client()) :: result()
  @callback list_payments(client()) :: result()
  @callback list_bank_transactions(client()) :: result()
  @callback list_bank_transfers(client()) :: result()
  @callback list_manual_journals(client()) :: result()
  @callback list_fixed_assets(client()) :: result()
  @callback get_conversion_balances(client()) :: result()
  @callback get_reports(client()) :: result()
  @callback get_trial_balance(client(), Date.t()) :: result()
end
