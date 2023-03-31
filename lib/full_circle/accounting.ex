defmodule FullCircle.Accounting do
  import Ecto.Query, warn: false
  import FullCircle.Authorization
  import FullCircle.Helpers
  alias FullCircle.Repo
  alias Ecto.Multi

  alias FullCircle.Accounting.Account
  alias FullCircle.Sys
  alias FullCircle.Sys.{Company, CompanyUser}

  def account_types do
    balance_sheet_account_types() ++ profit_loss_account_types()
  end

  defp balance_sheet_account_types do
    [
      "Cash or Equivalent",
      "Bank",
      "Current Asset",
      "Fixed Asset",
      "Inventory",
      "Non-current Asset",
      "Prepayment",
      "Equity",
      "Current Liability",
      "Liability",
      "Non-current Liability"
    ]
  end

  defp profit_loss_account_types do
    ["Depreciation", "Direct Costs", "Expenses", "Overhead", "Other Income", "Revenue", "Sales"]
  end

  def depreciation_methods do
    [
      "No Depreciation",
      "Straight-Line",
      "Declining Balance",
      "Declining Balance 150%",
      "Declining Balance 200%",
      "Full Depreciation at Purchase"
    ]
  end

  def get_account!(id), do: Repo.get!(Account, id)

  def filter_accounts(terms, company, user, page: page, per_page: per_page) do
    q =
      from(i in subquery(accounts_query(company, user)),
        offset: ^((page - 1) * per_page),
        limit: ^per_page
      )

    q =
      if(terms != "",
        do:
          from(i in q,
            order_by: ^similarity_order([:name, :account_type, :descriptions], terms),
            order_by: i.name
          ),
        else: from(i in q, order_by: i.name)
      )

    Repo.all(q)
  end

  defp accounts_query(company, user) do
    from(ac in Account,
      join: com in Company,
      on: com.id == ac.company_id,
      join: comuser in CompanyUser,
      on: com.id == comuser.company_id,
      join: user in FullCircle.UserAccounts.User,
      on: user.id == comuser.user_id,
      where: comuser.role != "disable",
      where: user.id == ^user.id,
      where: com.id == ^company.id,
      select: ac
    )
  end

  def create_account(attrs, user, company, multi \\ Multi.new()) do
    case can?(user, :create_account, company) do
      true ->
        multi
        |> Multi.insert(:create_account, account_changeset(%Account{}, attrs, company))
        |> Sys.insert_log_for(:create_account, attrs, company, user)
        |> Repo.transaction()
        |> case do
          {:ok, %{create_account: ac}} ->
            {:ok, ac}

          {:error, failed_operation, failed_value, changes_of_far} ->
            {:error, failed_operation, failed_value, changes_of_far}
        end

      false ->
        :not_authorise
    end
  end

  def update_account(ac, attrs, user, company) do
    case can?(user, :update_account, company) do
      true ->
        Multi.new()
        |> Multi.update(:update_account, account_changeset(ac, attrs, company))
        |> Sys.insert_log_for(:update_account, attrs, company, user)
        |> Repo.transaction()
        |> case do
          {:ok, %{update_account: nac}} ->
            {:ok, nac}

          {:error, failed_operation, failed_value, changes_of_far} ->
            {:error, failed_operation, failed_value, changes_of_far}
        end

      false ->
        :not_authorise
    end
  end

  def delete_account(ac, user, company) do
    case can?(user, :delete_account, company) and !is_default_account?(ac) do
      true ->
        Multi.new()
        |> Multi.delete(:delete_account, account_changeset(ac, %{}, company))
        |> Sys.insert_log_for(:delete_account, %{name: ac.name}, company, user)
        |> FullCircle.Repo.transaction()
        |> case do
          {:ok, %{delete_account: ac}} ->
            {:ok, ac}

          {:error, failed_operation, failed_value, changes_of_far} ->
            {:error, failed_operation, failed_value, changes_of_far}
        end

      false ->
        :not_authorise
    end
  end

  defp is_default_account?(ac) do
    Enum.any?(FullCircle.Sys.default_accounts(), fn a -> a.name == ac.name end)
  end

  def account_changeset(%Account{} = account, attrs \\ %{}, company) do
    Account.changeset(account, Map.merge(attrs, %{company_id: company.id}) |> key_to_string())
  end
end
