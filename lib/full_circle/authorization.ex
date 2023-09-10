defmodule FullCircle.Authorization do
  import Ecto.Query, warn: false

  def roles do
    ~w(guest admin manager supervisor cashier clerk disable auditor)
  end

  @allow true
  @forbid false

  def can?(user, :seed_taxcodes, company),
    do: allow_roles(~w(admin), company, user)

  def can?(user, :seed_goods, company),
    do: allow_roles(~w(admin), company, user)

  def can?(user, :seed_contacts, company),
    do: allow_roles(~w(admin), company, user)

  def can?(user, :seed_accounts, company),
    do: allow_roles(~w(admin), company, user)

  def can?(user, :seed_fixed_assets, company),
    do: allow_roles(~w(admin), company, user)

  def can?(user, :seed_fixed_asset_depreciations, company),
    do: allow_roles(~w(admin), company, user)

  def can?(user, :seed_transactions, company),
    do: allow_roles(~w(admin), company, user)

  def can?(user, :seed_transaction_matchers, company),
    do: allow_roles(~w(admin), company, user)

  def can?(user, :seed_balances, company),
    do: allow_roles(~w(admin), company, user)

  def can?(user, :create_fixed_asset_depreciation, company),
    do: allow_roles(~w(admin manager supervisor), company, user)

  def can?(user, :update_fixed_asset_depreciation, company),
    do: allow_roles(~w(admin manager supervisor), company, user)

  def can?(user, :delete_fixed_asset_depreciation, company),
    do: allow_roles(~w(admin manager supervisor), company, user)

  def can?(user, :create_fixed_asset_disposal, company),
    do: allow_roles(~w(admin manager supervisor), company, user)

  def can?(user, :update_fixed_asset_disposal, company),
    do: allow_roles(~w(admin manager supervisor), company, user)

  def can?(user, :delete_fixed_asset_disposal, company),
    do: allow_roles(~w(admin manager supervisor), company, user)

  def can?(user, :create_receipt, company),
    do: allow_roles(~w(admin manager supervisor clerk), company, user)

  def can?(user, :update_receipt, company),
    do: allow_roles(~w(admin manager supervisor clerk), company, user)

  def can?(user, :create_payment, company),
    do: allow_roles(~w(admin manager supervisor clerk), company, user)

  def can?(user, :update_payment, company),
    do: allow_roles(~w(admin manager supervisor clerk), company, user)

  def can?(user, :create_journal, company),
    do: allow_roles(~w(admin manager supervisor clerk), company, user)

  def can?(user, :update_journal, company),
    do: allow_roles(~w(admin manager supervisor clerk), company, user)

  def can?(user, :create_pur_invoice, company),
    do: allow_roles(~w(admin manager supervisor clerk), company, user)

  def can?(user, :update_pur_invoice, company),
    do: allow_roles(~w(admin manager supervisor clerk), company, user)

  def can?(user, :create_invoice, company),
    do: allow_roles(~w(admin manager supervisor clerk), company, user)

  def can?(user, :update_invoice, company),
    do: allow_roles(~w(admin manager supervisor clerk), company, user)

  def can?(user, :create_fixed_asset, company),
    do: allow_roles(~w(admin manager supervisor clerk), company, user)

  def can?(user, :update_fixed_asset, company),
    do: allow_roles(~w(admin manager supervisor clerk), company, user)

  def can?(user, :delete_fixed_asset, company),
    do: allow_roles(~w(admin manager supervisor clerk), company, user)

  def can?(user, :create_good, company),
    do: allow_roles(~w(admin manager supervisor clerk), company, user)

  def can?(user, :update_good, company),
    do: allow_roles(~w(admin manager supervisor clerk), company, user)

  def can?(user, :delete_good, company),
    do: allow_roles(~w(admin manager supervisor clerk), company, user)

  def can?(user, :create_account, company),
    do: allow_roles(~w(admin manager supervisor), company, user)

  def can?(user, :update_account, company),
    do: allow_roles(~w(admin manager supervisor), company, user)

  def can?(user, :delete_account, company),
    do: allow_roles(~w(admin manager supervisor), company, user)

  def can?(user, :create_tax_code, company),
    do: allow_roles(~w(admin manager supervisor), company, user)

  def can?(user, :update_tax_code, company),
    do: allow_roles(~w(admin manager supervisor), company, user)

  def can?(user, :delete_tax_code, company),
    do: allow_roles(~w(admin manager supervisor), company, user)

  def can?(user, :create_contact, company),
    do: forbid_roles(~w(auditor guest cashier), company, user)

  def can?(user, :update_contact, company),
    do: forbid_roles(~w(auditor guest cashier), company, user)

  def can?(user, :delete_contact, company),
    do: forbid_roles(~w(auditor guest cashier), company, user)

  def can?(user, :create_deposit, company),
    do: forbid_roles(~w(auditor guest), company, user)

  def can?(user, :update_deposit, company),
    do: forbid_roles(~w(auditor guest), company, user)

  def can?(user, :create_return_cheque, company),
    do: forbid_roles(~w(auditor guest), company, user)

  def can?(user, :update_return_cheque, company),
    do: forbid_roles(~w(auditor guest), company, user)

  def can?(user, :see_user_list, company), do: allow_role("admin", company, user)
  def can?(user, :invite_company, company), do: allow_role("admin", company, user)
  def can?(user, :add_user_to_company, company), do: allow_role("admin", company, user)
  def can?(user, :delete_company, company), do: allow_role("admin", company, user)
  def can?(user, :update_company, company), do: allow_role("admin", company, user)
  def can?(user, :reset_user_password, company), do: allow_role("admin", company, user)

  def can?(admin, :change_user_role, company, user) do
    if user_role_in_company(admin.id, company.id) == "admin" do
      if admin.id == user.id do
        @forbid
      else
        @allow
      end
    else
      @forbid
    end
  end

  defp user_role_in_company(user_id, company_id) do
    role = Util.attempt(FullCircle.Sys.get_company_user(company_id, user_id), :role)

    if role == nil do
      "disable"
    else
      role
    end
  end

  defp allow_role(role, company, user) when is_binary(role) do
    test_role = user_role_in_company(user.id, company.id)
    if role == test_role, do: @allow, else: @forbid
  end

  defp allow_roles(roles, company, user) when is_list(roles) do
    test_role = user_role_in_company(user.id, company.id)
    if Enum.find(roles, fn r -> r == test_role end), do: @allow, else: @forbid
  end

  defp forbid_roles(roles, company, user) when is_list(roles) do
    test_role = user_role_in_company(user.id, company.id)
    if Enum.find(roles, fn r -> r == test_role end), do: @forbid, else: @allow
  end

  # defp forbid_role(role, company, user) when is_binary(role) do
  #   test_role = user_role_in_company(user.id, company.id)
  #   if role == test_role, do: @forbid, else: @allow
  # end
end
