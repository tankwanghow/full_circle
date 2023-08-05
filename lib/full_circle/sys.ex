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
  alias FullCircle.Accounting.Account

  def default_gapless_doc(company_id) do
    [
      %{
        doc_type: "invoices",
        current: 0,
        company_id: company_id
      },
      %{
        doc_type: "pur_invoices",
        current: 0,
        company_id: company_id
      },
      %{
        doc_type: "journals",
        current: 0,
        company_id: company_id
      },
      %{
        doc_type: "debit_notes",
        current: 0,
        company_id: company_id
      },
      %{
        doc_type: "credit_notes",
        current: 0,
        company_id: company_id
      },
      %{
        doc_type: "deposits",
        current: 0,
        company_id: company_id
      },
      %{
        doc_type: "withdrawals",
        current: 0,
        company_id: company_id
      },
      %{
        doc_type: "return_cheques",
        current: 0,
        company_id: company_id
      },
      %{
        doc_type: "payments",
        current: 0,
        company_id: company_id
      },
      %{
        doc_type: "payslips",
        current: 0,
        company_id: company_id
      },
      %{
        doc_type: "salary_notes",
        current: 0,
        company_id: company_id
      },
      %{
        doc_type: "receipts",
        current: 0,
        company_id: company_id
      }
    ]
  end

  def default_tax_codes() do
    [%{code: "NoSTax"}, %{code: "NoPTax"}]
  end

  def default_tax_codes(company_id) do
    [
      %{
        code: "NoSTax",
        descriptions: "No Sales Tax",
        rate: 0.0,
        tax_type: "Sales",
        account_id:
          Repo.one!(
            from(a in Account,
              where: a.name == "Sales Tax Payable",
              where: a.company_id == ^company_id,
              select: a.id
            )
          )
      },
      %{
        code: "NoPTax",
        descriptions: "No Purchase Tax",
        rate: 0.00,
        tax_type: "Purchase",
        account_id:
          Repo.one!(
            from(a in Account,
              where: a.name == "Purchase Tax Receivable",
              where: a.company_id == ^company_id,
              select: a.id
            )
          )
      }
    ]
  end

  def default_accounts do
    [
      %{
        name: "General Purchases",
        account_type: "Cost Of Goods Sold",
        descriptions:
          "Account that shows the total amount a business spent on purchasing goods or services during a specific period, including all types of purchases. It helps businesses track their expenses and calculate their cost of goods sold, which is essential for determining their net profit."
      },
      %{
        name: "General Sales",
        account_type: "Revenue",
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
      },
      %{
        name: "Post Dated Cheques Received",
        account_type: "Post Dated Cheques",
        descriptions:
          "An Account in accounting that records the value of post-dated cheques received by a business but not yet deposited or cashed."
      }
    ]
  end

  def countries(), do: Enum.sort(Enum.map(Countries.all(), fn x -> "#{x.name}" end))

  def list_logs(entity, entity_id) do
    Repo.all(
      from log in Log,
        as: :logs,
        join: user in User,
        on: user.id == log.user_id,
        where: log.entity == ^entity,
        where: log.entity_id == ^entity_id,
        select: log,
        select_merge: %{email: user.email},
        order_by: log.inserted_at
    )
  end

  def get_setting(settings, page, code) do
    setting = Enum.find(settings, fn x -> x.page == page and x.code == code end)
    Map.get(setting.values, setting.value)
  end

  def get_setting(id) do
    Repo.get!(FullCircle.Sys.UserSetting, id)
  end

  def load_settings(page, company, user) do
    settings = Repo.all(load_settings_query(page, company, user))

    if Enum.count(settings) == 0 do
      insert_default_settings(page, company, user)
      Repo.all(load_settings_query(page, company, user))
    else
      settings
    end
  end

  def update_setting(setting, value) do
    cs = Ecto.Changeset.change(setting, %{value: value})
    Repo.update!(cs)
  end

  defp insert_default_settings(page, company, user) do
    cua =
      Repo.one!(
        from cu in CompanyUser,
          where: cu.user_id == ^user.id,
          where: cu.company_id == ^company.id
      )

    settings = FullCircle.Sys.UserSetting.default_settings(page, cua.id)

    Multi.new()
    |> Multi.insert_all(:insert_invoice_settings, FullCircle.Sys.UserSetting, settings)
    |> FullCircle.Repo.transaction()
  end

  defp load_settings_query(page, company, user) do
    from(st in FullCircle.Sys.UserSetting,
      join: cu in CompanyUser,
      on: st.company_user_id == cu.id,
      on: cu.user_id == ^user.id,
      on: cu.company_id == ^company.id,
      where: st.page == ^page,
      order_by: st.id
    )
  end

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

  def user_company(company, user) do
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

  def get_company_users(company, user) do
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
    |> Multi.insert_all(
      :create_default_tax_codes,
      FullCircle.Accounting.TaxCode,
      fn %{create_company: c} ->
        time = DateTime.truncate(Timex.now(), :second)

        default_tax_codes(c.id)
        |> Enum.map(fn x ->
          Map.merge(x, %{company_id: c.id, inserted_at: time, updated_at: time})
        end)
      end
    )
    |> Multi.insert_all(
      :create_default_gapless_doc,
      FullCircle.Sys.GaplessDocId,
      fn %{create_company: c} ->
        default_gapless_doc(c.id)
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
        where: log.entity_id == ^entity_id,
        order_by: log.inserted_at
      )
    )
  end

  def log_changeset(name, entity, entity_attrs, company, user) do
    Log.changeset(%Log{}, %{
      entity: entity.__meta__.source,
      entity_id: entity.id,
      action: Atom.to_string(name),
      delta: attr_to_string(entity_attrs),
      user_id: user.id,
      company_id: company.id
    })
  end

  def attr_to_string(attrs) do
    bl = ["_id", "delete"]

    if Enum.any?(attrs, fn {k, v} ->
         (k == "delete" or k == :delete) and v == "true"
       end) do
      ""
    else
      attrs
      |> Enum.map(fn {k, v} ->
        k = if(is_atom(k), do: Atom.to_string(k), else: k)

        if !String.ends_with?(k, bl) and k != "id" do
          if !is_map(v) do
            if v != "",
              do: "&^#{k}: #{Phoenix.HTML.html_escape(v) |> Phoenix.HTML.safe_to_string()}^&",
              else: nil
          else
            "&^#{k}: [" <> attr_to_string(v) <> "]^&"
          end
        end
      end)
      |> Enum.reject(fn x -> is_nil(x) end)
      |> Enum.join(" ")
    end
  end

  def company_changeset(company, attrs \\ %{}, user) do
    Company.changeset(company, attrs, user)
  end

  def company_user_changeset(company_user, attrs \\ %{}) do
    CompanyUser.changeset(company_user, attrs)
  end

  def get_user_default_company_by_email(email) do
    u = FullCircle.UserAccounts.get_user_by_email(email)
    c = get_default_company(u)
    {u, c}
  end
end
