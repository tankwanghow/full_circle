defmodule FullCircle.HR do
  import Ecto.Query, warn: false
  import FullCircle.Helpers
  import FullCircle.Authorization
  alias Ecto.Multi

  alias FullCircle.HR.{
    Employee,
    SalaryType,
    EmployeeSalaryType,
    Advance,
    PaySlip,
    SalaryNote,
    Recurring
  }

  alias FullCircle.Accounting.{Account, Transaction}
  alias FullCircle.Accounting
  alias FullCircle.{Repo, Sys, StdInterface}

  def get_recurring!(id, company, user) do
    from(note in recurring_query(company, user),
      where: note.id == ^id,
    )
    |> Repo.one!()
  end

  def recurring_query(company, user) do
    from(note in Recurring,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == note.company_id,
      join: emp in Employee,
      on: emp.id == note.employee_id,
      join: st in SalaryType,
      on: st.id == note.salary_type_id,
      select: note,
      select_merge: %{
        employee_name: emp.name,
        salary_type_name: st.name
      })
  end

  def get_print_advances!(ids, company, user) do
    Repo.all(
      from rec in Advance,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == rec.company_id,
        where: rec.id in ^ids,
        preload: [:employee, :funds_account],
        select: rec
    )
  end

  def get_print_salary_notes!(ids, company, user) do
    Repo.all(
      from rec in SalaryNote,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == rec.company_id,
        where: rec.id in ^ids,
        preload: [:employee, :salary_type],
        select: rec
    )
  end

  def get_salary_note!(id, com, user) do
    from(note in salary_note_query(com, user),
      where: note.id == ^id
    )
    |> Repo.one!()
  end

  def salary_note_query(company, user) do
    from(note in SalaryNote,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == note.company_id,
      join: emp in Employee,
      on: emp.id == note.employee_id,
      join: st in SalaryType,
      on: st.id == note.salary_type_id,
      left_join: pay in PaySlip,
      on: pay.id == note.pay_slip_id,
      select: note,
      select_merge: %{
        employee_name: emp.name,
        salary_type_name: st.name,
        pay_slip_no: pay.slip_no
      }
    )
  end

  def salary_note_index_query(terms, date_from, com, user,
        page: page,
        per_page: per_page
      ) do
    qry =
      from(inv in subquery(salary_note_raw_query(com, user)))

    qry =
      if terms != "" do
        from inv in subquery(qry),
          order_by:
            ^similarity_order(
              [:note_no, :employee_name, :salary_type_name, :particulars],
              terms
            )
      else
        qry
      end

    qry =
      if date_from != "" do
        from inv in qry, where: inv.note_date >= ^date_from, order_by: inv.note_date
      else
        qry
      end

    qry |> offset((^page - 1) * ^per_page) |> limit(^per_page) |> Repo.all()
  end

  def get_salary_note_by_id_index_component_field!(id, com, user) do
    from(i in subquery(salary_note_raw_query(com, user)),
      where: i.id == ^id
    )
    |> Repo.one!()
  end

  defp salary_note_raw_query(company, user) do
    from txn in Transaction,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == txn.company_id and txn.doc_type == "SalaryNote",
      left_join: note in SalaryNote,
      on: txn.doc_no == note.note_no,
      left_join: emp in Employee,
      on: emp.id == note.employee_id,
      left_join: st in SalaryType,
      on: st.id == note.salary_type_id,
      order_by: [desc: txn.inserted_at],
      where: txn.amount > 0,
      select: %{
        id: coalesce(note.id, txn.id),
        note_no: txn.doc_no,
        employee_name: emp.name,
        salary_type_name: st.name,
        particulars: coalesce(note.descriptions, txn.particulars),
        note_date: txn.doc_date,
        updated_at: txn.inserted_at,
        company_id: com.id,
        amount: txn.amount,
        checked: false,
        old_data: txn.old_data
      },
      group_by: [
        coalesce(note.id, txn.id),
        txn.doc_no,
        txn.doc_date,
        com.id,
        txn.old_data,
        txn.inserted_at,
        txn.amount,
        emp.name,
        st.name,
        coalesce(note.descriptions, txn.particulars)
      ]
  end

  def create_salary_note(attrs, com, user) do
    case can?(user, :create_salary_note, com) do
      true ->
        Multi.new()
        |> create_salary_note_multi(attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  end

  def create_salary_note_multi(multi, attrs, com, user) do
    gapless_name = String.to_atom("update_gapless_doc" <> gen_temp_id())
    note_name = :create_salary_note

    multi
    |> get_gapless_doc_id(gapless_name, "SalaryNote", "SN", com)
    |> Multi.insert(
      note_name,
      fn mty ->
        doc = Map.get(mty, gapless_name)

        StdInterface.changeset(
          SalaryNote,
          %SalaryNote{},
          Map.merge(attrs, %{"note_no" => doc}),
          com
        )
      end
    )
    |> Multi.insert("#{note_name}_log", fn %{^note_name => entity} ->
      FullCircle.Sys.log_changeset(
        note_name,
        entity,
        Map.merge(attrs, %{"note_no" => entity.note_no}),
        com,
        user
      )
    end)
    |> create_salary_note_transactions(note_name, com, user)
  end

  def create_salary_note_transactions(multi, name, com, _user) do
    multi
    |> Ecto.Multi.run("create_transactions", fn repo, %{^name => note} ->
      note = note |> FullCircle.Repo.preload(:salary_type)

      repo.insert!(%Transaction{
        doc_type: "SalaryNote",
        doc_no: note.note_no,
        doc_id: note.id,
        doc_date: note.note_date,
        account_id: note.salary_type.cr_ac_id,
        company_id: com.id,
        amount: Decimal.negate(note.amount),
        particulars: "#{note.salary_type_name} to #{note.employee_name}"
      })

      repo.insert!(%Transaction{
        doc_type: "SalaryNote",
        doc_no: note.note_no,
        doc_id: note.id,
        doc_date: note.note_date,
        account_id: note.salary_type.db_ac_id,
        company_id: com.id,
        amount: note.amount,
        particulars: "#{note.salary_type_name} to #{note.employee_name}"
      })

      {:ok, nil}
    end)
  end

  def update_salary_note(%SalaryNote{} = salary_note, attrs, com, user) do
    case can?(user, :update_salary_note, com) do
      true ->
        Multi.new()
        |> update_salary_note_multi(salary_note, attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  rescue
    e in Postgrex.Error ->
      {:sql_error, e.postgres.message}
  end

  def update_salary_note_multi(multi, salary_note, attrs, com, user) do
    salary_note_name = :update_salary_note

    multi
    |> Multi.update(salary_note_name, StdInterface.changeset(SalaryNote, salary_note, attrs, com))
    |> Multi.delete_all(
      :delete_transaction,
      from(txn in Transaction,
        where: txn.doc_type == "SalaryNote",
        where: txn.doc_no == ^salary_note.note_no,
        where: txn.company_id == ^com.id
      )
    )
    |> Sys.insert_log_for(salary_note_name, attrs, com, user)
    |> create_salary_note_transactions(salary_note_name, com, user)
  end

  def get_advance!(id, com, user) do
    from(adv in advance_query(com, user),
      where: adv.id == ^id
    )
    |> Repo.one!()
  end

  def advance_query(company, user) do
    from(adv in Advance,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == adv.company_id,
      join: emp in Employee,
      on: emp.id == adv.employee_id,
      join: ac in Account,
      on: ac.id == adv.funds_account_id,
      left_join: pay in PaySlip,
      on: pay.id == adv.pay_slip_id,
      select: adv,
      select_merge: %{
        employee_name: emp.name,
        funds_account_name: ac.name,
        pay_slip_no: pay.slip_no
      }
    )
  end

  def advance_index_query(terms, date_from, com, user,
        page: page,
        per_page: per_page
      ) do
    qry =
      from(inv in subquery(advance_raw_query(com, user)))

    qry =
      if terms != "" do
        from inv in subquery(qry),
          order_by:
            ^similarity_order(
              [:slip_no, :employee_name, :funds_account_name, :particulars],
              terms
            )
      else
        qry
      end

    qry =
      if date_from != "" do
        from inv in qry, where: inv.slip_date >= ^date_from, order_by: inv.slip_date
      else
        qry
      end

    qry |> offset((^page - 1) * ^per_page) |> limit(^per_page) |> Repo.all()
  end

  def get_advance_by_id_index_component_field!(id, com, user) do
    from(i in subquery(advance_raw_query(com, user)),
      where: i.id == ^id
    )
    |> Repo.one!()
  end

  defp advance_raw_query(company, user) do
    from txn in Transaction,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == txn.company_id and txn.doc_type == "Advance",
      left_join: adv in Advance,
      on: txn.doc_no == adv.slip_no,
      left_join: emp in Employee,
      on: emp.id == adv.employee_id,
      left_join: funds in Account,
      on: funds.id == adv.funds_account_id,
      order_by: [desc: txn.inserted_at],
      where: txn.amount > 0,
      select: %{
        id: coalesce(adv.id, txn.id),
        slip_no: txn.doc_no,
        employee_name: emp.name,
        funds_account_name: funds.name,
        particulars: coalesce(adv.note, txn.particulars),
        slip_date: txn.doc_date,
        updated_at: txn.inserted_at,
        company_id: com.id,
        amount: txn.amount,
        checked: false,
        old_data: txn.old_data
      },
      group_by: [
        coalesce(adv.id, txn.id),
        txn.doc_no,
        txn.doc_date,
        com.id,
        txn.old_data,
        txn.inserted_at,
        txn.amount,
        emp.name,
        funds.name,
        coalesce(adv.note, txn.particulars)
      ]
  end

  def create_advance(attrs, com, user) do
    case can?(user, :create_advance, com) do
      true ->
        Multi.new()
        |> create_advance_multi(attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  end

  def create_advance_multi(multi, attrs, com, user) do
    gapless_name = String.to_atom("update_gapless_doc" <> gen_temp_id())
    note_name = :create_advance

    multi
    |> get_gapless_doc_id(gapless_name, "Advance", "ADV", com)
    |> Multi.insert(
      note_name,
      fn mty ->
        doc = Map.get(mty, gapless_name)

        StdInterface.changeset(
          Advance,
          %Advance{},
          Map.merge(attrs, %{"slip_no" => doc}),
          com
        )
      end
    )
    |> Multi.insert("#{note_name}_log", fn %{^note_name => entity} ->
      FullCircle.Sys.log_changeset(
        note_name,
        entity,
        Map.merge(attrs, %{"slip_no" => entity.slip_no}),
        com,
        user
      )
    end)
    |> create_advance_transactions(note_name, com, user)
  end

  defp create_advance_transactions(multi, name, com, user) do
    paya_id = Accounting.get_account_by_name("Salaries and Wages Payable", com, user).id

    multi
    |> Ecto.Multi.run("create_transactions", fn repo, %{^name => adv} ->
      repo.insert!(%Transaction{
        doc_type: "Advance",
        doc_no: adv.slip_no,
        doc_id: adv.id,
        doc_date: adv.slip_date,
        account_id: paya_id,
        company_id: com.id,
        amount: adv.amount,
        particulars: "From #{adv.funds_account_name} to #{adv.employee_name}"
      })

      repo.insert!(%Transaction{
        doc_type: "Advance",
        doc_no: adv.slip_no,
        doc_id: adv.id,
        doc_date: adv.slip_date,
        account_id: adv.funds_account_id,
        company_id: com.id,
        amount: Decimal.negate(adv.amount),
        particulars: "From #{adv.funds_account_name} to #{adv.employee_name}"
      })

      {:ok, nil}
    end)
  end

  def update_advance(%Advance{} = advance, attrs, com, user) do
    case can?(user, :update_advance, com) do
      true ->
        Multi.new()
        |> update_advance_multi(advance, attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  rescue
    e in Postgrex.Error ->
      {:sql_error, e.postgres.message}
  end

  def update_advance_multi(multi, advance, attrs, com, user) do
    advance_name = :update_advance

    multi
    |> Multi.update(advance_name, StdInterface.changeset(Advance, advance, attrs, com))
    |> Multi.delete_all(
      :delete_transaction,
      from(txn in Transaction,
        where: txn.doc_type == "Advance",
        where: txn.doc_no == ^advance.slip_no,
        where: txn.company_id == ^com.id
      )
    )
    |> Sys.insert_log_for(advance_name, attrs, com, user)
    |> create_advance_transactions(advance_name, com, user)
  end

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
      select: %{id: st.id, value: st.name},
      order_by: st.name
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

  def get_employee_by_name(name, company, user) do
    name = name |> String.trim()

    from(emp in employee_query(company, user),
      where: emp.name == ^name
    )
    |> Repo.one()
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
      select: %{id: emp.id, value: emp.name},
      order_by: emp.name
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
