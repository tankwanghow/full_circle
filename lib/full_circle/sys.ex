defmodule FullCircle.Sys do
  import Ecto.Query, warn: false
  import FullCircle.Authorization
  import FullCircle.Helpers

  alias FullCircle.Repo
  alias Ecto.Multi
  alias FullCircle.UserAccounts.User
  alias FullCircle.Sys.Company
  alias FullCircle.Sys.CompanyUser
  alias FullCircle.Sys.Log

  def default_accounts do
    [
      %{
        name: "General Purchase",
        account_type: "Expenses",
        descriptions:
          "Account that shows the total amount a business spent on purchasing goods or services during a specific period, including all types of purchases. It helps businesses track their expenses and calculate their cost of goods sold, which is essential for determining their net profit."
      },
      %{
        name: "General Sales",
        account_type: "Sales",
        descriptions:
          "Account that shows the total purchases made by a business during a specific period, including all types of sales. It helps businesses track their revenue and calculate their gross profit."
      },
      %{
        name: "Account Payables",
        account_type: "Current Liability",
        descriptions:
          "Is a liability account in accounting that represents the money a business owes to its creditors for goods or services received but not yet paid for. It helps businesses keep track of outstanding payments owed and manage their relationships with suppliers."
      },
      %{
        name: "Account Receivables",
        account_type: "Current Asset",
        descriptions:
          "Is a asset account in accounting that represents the money a business is owed by its customers for goods or services sold on credit. It helps businesses keep track of outstanding payments owed and manage their cash flow."
      },
      %{
        name: "Sales Tax Payable",
        account_type: "Current Liability",
        descriptions:
          "Is a liability account in accounting that represents the sales tax collected by a business from customers but not yet paid to the government. It helps businesses keep track of outstanding sales tax owed and avoid penalties and interest charges."
      },
      %{
        name: "Purchase Tax Receivable",
        account_type: "Current Asset",
        descriptions:
          "Is an asset account in accounting that represents the amount of tax credit a business can claim for taxes paid on its purchases. It helps businesses reduce their tax liability in the future."
      }
    ]
  end

  def countries(), do: Enum.sort(Enum.map(Countries.all(), fn x -> "#{x.name}" end))

  def get_company!(id) do
    Repo.get!(Company, id)
  end

  def user_companies(user) do
    from(c in Company,
      join: cu in CompanyUser,
      on: c.id == cu.company_id,
      where: cu.user_id == ^user.id,
      where: cu.role != "disable"
    )
  end

  def user_companies(company, user) do
    from(c in Company,
      join: cu in CompanyUser,
      on: c.id == cu.company_id,
      where: cu.user_id == ^user.id,
      where: cu.role != "disable",
      where: c.id == ^company.id
    )
  end

  def get_company_user(company_id, user_id) do
    Repo.one(
      from(cu in CompanyUser, where: cu.company_id == ^company_id, where: cu.user_id == ^user_id)
    )
  end

  def get_company_users(user, company) do
    if can?(user, :see_user_list, company) do
      Repo.all(
        from(u in User,
          join: cu in CompanyUser,
          on: u.id == cu.user_id,
          where: cu.company_id == ^company.id,
          order_by: u.email,
          select: %{id: u.id, email: u.email, role: cu.role}
        )
      )
    else
      [
        Repo.one(
          from(u in User,
            join: cu in CompanyUser,
            on: u.id == cu.user_id,
            where: cu.company_id == ^company.id,
            where: cu.user_id == ^user.id,
            select: %{id: u.id, email: u.email, role: cu.role}
          )
        )
      ]
    end
  end

  def get_default_company(user) do
    Repo.one(
      from(cu in subquery(companies_query(user.id)),
        where: cu.default_company == true
      )
    )
  end

  def list_companies(user) do
    Repo.all(companies_query(user.id))
  end

  defp companies_query(user_id) do
    from(c in Company,
      join: cu in CompanyUser,
      on: c.id == cu.company_id,
      where: cu.user_id == ^user_id,
      where: cu.role != "disable",
      order_by: c.name,
      select: %{
        address1: c.address1,
        address2: c.address2,
        city: c.city,
        country: c.country,
        company_id: cu.company_id,
        user_id: cu.user_id,
        name: c.name,
        state: c.state,
        zipcode: c.zipcode,
        closing_month: c.closing_month,
        closing_day: c.closing_day,
        reg_no: c.reg_no,
        tax_id: c.tax_id,
        tel: c.tel,
        fax: c.fax,
        descriptions: c.descriptions,
        timezone: c.timezone,
        email: c.email,
        default_company: cu.default_company,
        role: cu.role,
        updated_at: c.updated_at,
        id: c.id
      }
    )
  end

  def create_company(attrs \\ %{}, user) do
    Multi.new()
    |> Multi.insert(:create_company, company_changeset(%Company{}, attrs, user))
    |> Multi.insert(:create_company_user, fn %{create_company: c} ->
      if Repo.aggregate(companies_query(user.id), :count) > 0,
        do:
          company_user_changeset(%CompanyUser{}, %{
            company_id: c.id,
            user_id: user.id,
            role: "admin"
          }),
        else:
          company_user_changeset(%CompanyUser{}, %{
            company_id: c.id,
            user_id: user.id,
            role: "admin",
            default_company: true
          })
    end)
    |> Multi.insert_all(
      :create_default_accounts,
      FullCircle.Accounting.Account,
      fn %{create_company: c} ->
        time = DateTime.truncate(Timex.now(), :second)

        default_accounts()
        |> Enum.map(fn x ->
          Map.merge(x, %{company_id: c.id, inserted_at: time, updated_at: time})
        end)
      end
    )
    |> FullCircle.Repo.transaction()
    |> case do
      {:ok, %{create_company: company}} ->
        {:ok, company}

      {:error, failed_operation, failed_value, changes_so_far} ->
        {:error, failed_operation, failed_value, changes_so_far}
    end
  end

  def update_company(company, attrs \\ %{}, user) do
    case can?(user, :update_company, company) do
      true ->
        Multi.new()
        |> Multi.update(:update_company, company_changeset(company, attrs, user))
        |> FullCircle.Repo.transaction()
        |> case do
          {:ok, %{update_company: company}} ->
            {:ok, company}

          {:error, failed_operation, failed_value, changes_so_far} ->
            {:error, failed_operation, failed_value, changes_so_far}
        end

      false ->
        :not_authorise
    end
  end

  def delete_company(company, user) do
    case can?(user, :delete_company, company) do
      true ->
        Multi.new()
        |> Multi.delete(:delete_company, company)
        |> FullCircle.Repo.transaction()
        |> case do
          {:ok, %{delete_company: company}} ->
            {:ok, company}

          {:error, failed_operation, failed_value, changes_so_far} ->
            {:error, failed_operation, failed_value, changes_so_far}
        end

      false ->
        :not_authorise
    end
  end

  def set_default_company(user_id, company_id) do
    update_default_company_query =
      from(fu in CompanyUser,
        where: fu.company_id == ^company_id and fu.user_id == ^user_id
      )

    update_not_default_company_query =
      from(fu in CompanyUser,
        where: fu.company_id != ^company_id and fu.user_id == ^user_id
      )

    Multi.new()
    |> Multi.update_all(:default, update_default_company_query, set: [default_company: true])
    |> Multi.update_all(:not_default, update_not_default_company_query,
      set: [default_company: false]
    )
    |> FullCircle.Repo.transaction()
    |> case do
      {:ok, %{default: company}} ->
        {:ok, company}

      {:error, failed_operation, failed_value, changes_so_far} ->
        {:error, failed_operation, failed_value, changes_so_far}
    end
  end

  def allow_user_to_access(com, user, role, admin) do
    case can?(admin, :add_user_to_company, com) do
      true ->
        case Repo.insert(
               company_user_changeset(%CompanyUser{}, %{
                 company_id: com.id,
                 user_id: user.id,
                 role: role
               })
             ) do
          {:ok, struct} -> {:ok, struct}
          {:error, changeset} -> {:error, changeset}
        end

      false ->
        :not_authorise
    end
  end

  def add_user_to_company(com, email, role, admin) do
    case can?(admin, :add_user_to_company, com) do
      true ->
        user = FullCircle.UserAccounts.get_user_by_email(email)

        if user do
          case allow_user_to_access(com, user, role, admin) do
            {:ok, cu} -> {:ok, {user, cu, nil}}
            {:error, cs} -> {:error, cs}
          end
        else
          pwd = gen_temp_id(12)

          Multi.new()
          |> Multi.insert(
            :register_user,
            User.admin_add_user_changeset(%User{}, %{
              email: email,
              password: pwd,
              password_confirmation: pwd,
              company_id: com.id
            })
          )
          |> Multi.insert(:allow_user_access_company, fn %{register_user: u} ->
            company_user_changeset(%CompanyUser{}, %{
              company_id: com.id,
              user_id: u.id,
              role: role
            })
          end)
          |> FullCircle.Repo.transaction()
          |> case do
            {:ok, %{register_user: user, allow_user_access_company: cu}} -> {:ok, {user, cu, pwd}}
            {:error, fail_at, fail_value, _} -> {:error, fail_at, fail_value}
          end
        end

      false ->
        :not_authorise
    end
  end

  def change_user_role_in(com, user_id, role, admin) do
    case can?(admin, :change_user_role, com, %{id: user_id}) do
      true ->
        com_user = get_company_user(com.id, user_id)

        Repo.update(
          company_user_changeset(com_user, %{
            role: role
          })
        )

      false ->
        :not_authorise
    end
  end

  def reset_user_password(user, admin, com) do
    case can?(admin, :reset_user_password, com) do
      true ->
        pwd = gen_temp_id(12)

        changeset =
          user
          |> User.password_changeset(%{"password" => pwd, "password_confirmation" => pwd})

        Ecto.Multi.new()
        |> Ecto.Multi.update(:user, changeset)
        |> Ecto.Multi.delete_all(
          :tokens,
          FullCircle.UserAccounts.UserToken.user_and_contexts_query(user, :all)
        )
        |> Repo.transaction()
        |> case do
          {:ok, %{user: user}} ->
            {:ok, user, pwd}

          {:error, :user, changeset, _} ->
            {:error, changeset}
        end

      false ->
        :not_authorise
    end
  end

  def insert_log_for(multi, name, entity_attrs, company, user) do
    Ecto.Multi.insert(multi, "#{name}_log", fn %{^name => entity} ->
      log_changeset(name, entity, entity_attrs, company, user)
    end)
  end

  def log_entry_for(entity, entity_id, company_id) do
    Repo.all(
      from(log in Log,
        where: log.company_id == ^company_id,
        where: log.entity == ^entity,
        where: log.entity_id == ^entity_id
      )
    )
  end

  defp log_changeset(name, entity, entity_attrs, company, user) do
    Log.changeset(%Log{}, %{
      entity: entity.__meta__.source,
      entity_id: entity.id,
      action: Atom.to_string(name),
      delta: attr_to_string(entity_attrs),
      user_id: user.id,
      company_id: company.id
    })
  end

  defp attr_to_string(attrs) do
    attrs
    |> Enum.map(fn {k, v} ->
      if !is_map(v) do
        "#{k}: #{v}"
      else
        "#{k}: [" <> attr_to_string(v) <> "]"
      end
    end)
    |> Enum.join(" | ")
  end

  def company_changeset(company, attrs \\ %{}, user) do
    Company.changeset(company, attrs, user)
  end

  def company_user_changeset(company_user, attrs \\ %{}) do
    CompanyUser.changeset(company_user, attrs)
  end
end
