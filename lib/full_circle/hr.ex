defmodule FullCircle.HR do
  import Ecto.Query, warn: false

  alias FullCircle.HR.{Employee, SalaryType, EmployeeSalaryType}
  alias FullCircle.Accounting.Account
  alias FullCircle.{Repo, Sys}

  def get_salary_type!(id, com, user) do
    from(st in salary_type_query(com, user),
      where: st.id == ^id
    )
    |> Repo.one!()
  end

  def get_salary_type_by_name(name, company, user) do
    name = name |> String.trim()

    from(st in salary_type_query(company, user),
      where: st.name == ^name
    )
    |> Repo.one()
  end

  def salary_types(terms, company, user) do
    from(st in SalaryType,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == st.company_id,
      where: ilike(st.name, ^"%#{terms}%"),
      select: %{id: st.id, value: st.name}
    )
    |> Repo.all()
  end

  def salary_type_query(company, user) do
    from(st in SalaryType,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == st.company_id,
      join: dbac in Account,
      on: dbac.id == st.db_ac_id,
      join: crac in Account,
      on: crac.id == st.cr_ac_id,
      select: st,
      select_merge: %{db_ac_name: dbac.name, cr_ac_name: crac.name}
    )
  end

  defp employee_salary_types() do
    from(est in EmployeeSalaryType,
      join: st in SalaryType,
      on: st.id == est.salary_type_id,
      select: est,
      select_merge: %{salary_type_name: st.name}
    )
  end

  def get_employee!(id, com, user) do
    from(emp in employee_query(com, user),
      preload: [employee_salary_types: ^employee_salary_types()],
      where: emp.id == ^id
    )
    |> Repo.one!()
  end

  def employees(terms, company, user) do
    from(emp in employee_query(company, user),
      where: ilike(emp.name, ^"%#{terms}%"),
      select: %{id: emp.id, value: emp.name}
    )
    |> Repo.all()
  end

  defp employee_query(company, user) do
    from(emp in Employee,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == emp.company_id
    )
  end
end
