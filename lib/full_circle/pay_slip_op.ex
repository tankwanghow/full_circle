defmodule FullCircle.PaySlipOp do
  import Ecto.Query, warn: false
  import Ecto.Changeset
  import FullCircle.Helpers
  import FullCircle.Authorization
  alias FullCircle.Sys.Log
  alias Ecto.Multi

  alias FullCircle.HR.{
    Employee,
    SalaryType,
    Advance,
    PaySlip,
    SalaryNote,
    Recurring
  }

  alias FullCircle.Accounting.{Account, Transaction}
  alias FullCircle.{Accounting, SalaryNoteCalFunc}
  alias FullCircle.Sys.Company
  alias FullCircle.{Repo, Sys, StdInterface, HR}

  def calculate_pay(cs, emp) do
    sns =
      (fetch_field!(cs, :additions) ++
         fetch_field!(cs, :bonuses) ++
         fetch_field!(cs, :deductions) ++
         fetch_field!(cs, :contributions) ++ fetch_field!(cs, :leaves))
      |> Enum.map(fn x ->
        if !is_nil(x.cal_func) do
          val =
            SalaryNoteCalFunc.calculate_value(
              x.cal_func |> String.to_atom(),
              emp,
              cs
            )

          SalaryNote.changeset_on_payslip(x, %{
            unit_price: val,
            quantity: 1,
            amount: val
          })
        else
          SalaryNote.changeset_on_payslip(x, %{})
        end
      end)

    add = sns |> Enum.filter(fn x -> fetch_field!(x, :salary_type_type) == "Addition" end)
    ded = sns |> Enum.filter(fn x -> fetch_field!(x, :salary_type_type) == "Deduction" end)
    con = sns |> Enum.filter(fn x -> fetch_field!(x, :salary_type_type) == "Contribution" end)
    lea = sns |> Enum.filter(fn x -> fetch_field!(x, :salary_type_type) == "LeaveTaken" end)
    bon = sns |> Enum.filter(fn x -> fetch_field!(x, :salary_type_type) == "Bonus" end)

    cs
    |> put_assoc(:additions, add)
    |> put_assoc(:bonuses, bon)
    |> put_assoc(:deductions, ded)
    |> put_assoc(:contributions, con)
    |> put_assoc(:leaves, lea)
    |> PaySlip.compute_fields()
  end

  defp generate_pay_slip_children(emp, mth, yr, com, user) do
    sns = get_uncount_salary_notes(emp.id, com)
    adv = get_uncount_advances(emp.id, com)
    rec = get_uncount_recurrings(emp.id, mth, yr, com)

    pcb_type = HR.get_salary_type_by_name("Employee PCB", com, user)

    sts =
      (HR.get_employee_salary_types(emp.id) ++
         [
           %{
             id: pcb_type.id,
             name: pcb_type.name,
             type: pcb_type.type,
             cal_func: pcb_type.cal_func,
             amount: 0
           }
         ])
      |> Enum.uniq_by(fn %{id: id} -> id end)
      |> Enum.reject(fn x -> x.type == "Addition" end)
      |> Enum.reject(fn x ->
        Enum.any?(sns, fn y ->
          y.salary_type_id == x.id
        end)
      end)

    sns =
      sns ++
        rec ++
        Enum.map(sts, fn t ->
          %{
            _id: nil,
            note_no: "...new...",
            note_date: Timex.end_of_month(yr, mth),
            unit_price: t.amount,
            quantity: 1,
            amount: 0,
            salary_type_id: t.id,
            salary_type_name: t.name,
            salary_type_type: t.type,
            cal_func: t.cal_func,
            company_id: com.id,
            employee_id: emp.id,
            delete: false,
            recurring_id: nil
          }
        end)

    add = sns |> Enum.filter(fn x -> x.salary_type_type == "Addition" end)
    ded = sns |> Enum.filter(fn x -> x.salary_type_type == "Deduction" end)
    con = sns |> Enum.filter(fn x -> x.salary_type_type == "Contribution" end)
    lea = sns |> Enum.filter(fn x -> x.salary_type_type == "LeaveTaken" end)
    bon = sns |> Enum.filter(fn x -> x.salary_type_type == "Bonus" end)

    {add, bon, ded, con, lea, adv}
  end

  def generate_new_changeset_for(emp, mth, yr, com, user) do
    {add, bon, ded, con, lea, adv} = generate_pay_slip_children(emp, mth, yr, com, user)

    StdInterface.changeset(
      PaySlip,
      %PaySlip{},
      %{
        employee_id: emp.id,
        slip_no: "...new...",
        employee_name: emp.name,
        slip_date: Timex.today(),
        pay_year: yr,
        pay_month: mth,
        additions: add,
        bonuses: bon,
        deductions: ded,
        contributions: con,
        leaves: lea,
        advances: adv
      },
      com
    )
  end

  def get_uncount_recurrings(emp_id, mth, yr, comp) do
    edate = Timex.end_of_month(yr, mth)

    from(rcr in Recurring,
      join: com in Company,
      on: rcr.start_date <= ^edate,
      on: com.id == rcr.company_id,
      on: com.id == ^comp.id,
      join: emp in Employee,
      on: emp.id == rcr.employee_id,
      on: emp.id == ^emp_id,
      join: st in SalaryType,
      on: st.id == rcr.salary_type_id,
      left_join: sn in SalaryNote,
      on: sn.recurring_id == rcr.id,
      where: rcr.status == "Active",
      select: %{
        _id: nil,
        note_no: "...new...",
        note_date: fragment("?::date", ^edate),
        unit_price: rcr.amount,
        quantity: 1,
        amount: rcr.amount,
        sum_sn_amount: sum(coalesce(sn.quantity, 0) * coalesce(sn.unit_price, 0)),
        descriptions: fragment("'Recurrnig Deduct' || ' ' || ?", rcr.recur_no),
        salary_type_id: rcr.salary_type_id,
        salary_type_name: st.name,
        salary_type_type: st.type,
        cal_func: st.cal_func,
        company_id: com.id,
        employee_id: emp.id,
        delete: false,
        target_amount: rcr.target_amount,
        recurring_id: rcr.id
      },
      group_by: [rcr.id, st.id, com.id, emp.id],
      having: rcr.target_amount > sum(coalesce(sn.quantity, 0) * coalesce(sn.unit_price, 0))
    )
    |> Repo.all()
    |> Enum.map(fn x ->
      cond do
        x.target_amount |> Decimal.compare(x.sum_sn_amount) == :eq ->
          nil

        x.target_amount |> Decimal.sub(x.sum_sn_amount) |> Decimal.compare(x.amount) == :gt ->
          Map.merge(x, %{unit_price: x.amount, quantity: x.quantity, amount: x.amount})

        x.target_amount |> Decimal.sub(x.sum_sn_amount) |> Decimal.compare(x.amount) == :lt ->
          amt = x.target_amount |> Decimal.sub(x.sum_sn_amount)
          Map.merge(x, %{unit_price: amt, quantity: x.quantity, amount: amt})
      end
    end)
    |> Enum.map(fn x ->
      Map.reject(x, fn {k, _} -> k == :target_amount or k == :sum_sn_amount end)
    end)
  end

  def get_uncount_advances(emp_id, comp) do
    from(adv in subquery(advance_query()),
      where: is_nil(adv.pay_slip_id),
      where: adv.company_id == ^comp.id,
      where: adv.employee_id == ^emp_id,
      select: %{
        slip_no: adv.slip_no,
        slip_date: adv.slip_date,
        note: adv.note,
        amount: adv.amount,
        _id: adv.id,
        company_id: adv.company_id,
        employee_id: adv.employee_id,
        funds_account_id: adv.funds_account_id,
        pay_slip_id: nil,
        delete: false
      }
    )
    |> Repo.all()
  end

  defp advance_query() do
    from(adv in Advance,
      join: com in Company,
      on: com.id == adv.company_id,
      join: emp in Employee,
      on: emp.id == adv.employee_id,
      select: adv,
      select_merge: %{_id: adv.id}
    )
  end

  defp salary_note_query() do
    from(note in SalaryNote,
      join: com in Company,
      on: com.id == note.company_id,
      join: emp in Employee,
      on: emp.id == note.employee_id,
      join: st in SalaryType,
      on: st.id == note.salary_type_id,
      select: note,
      select_merge: %{
        _id: note.id,
        salary_type_id: st.id,
        salary_type_name: st.name,
        salary_type_type: st.type,
        cal_func: st.cal_func,
        descriptions: note.descriptions,
        amount: fragment("round(? * ?, 2)", note.quantity, note.unit_price),
        employee_id: emp.id,
        company_id: com.id,
        delete: false
      }
    )
  end

  def get_uncount_salary_notes(emp_id, comp) do
    from(note in subquery(salary_note_query()),
      where: is_nil(note.pay_slip_id),
      where: note.employee_id == ^emp_id,
      where: note.company_id == ^comp.id,
      select: %{
        _id: note.id,
        note_no: note.note_no,
        note_date: note.note_date,
        salary_type_id: note.salary_type_id,
        salary_type_name: note.salary_type_name,
        salary_type_type: note.salary_type_type,
        quantity: note.quantity,
        unit_price: note.unit_price,
        amount: fragment("round(? * ?, 2)", note.quantity, note.unit_price),
        descriptions: note.descriptions,
        cal_func: note.cal_func,
        employee_id: note.employee_id,
        company_id: note.company_id,
        pay_slip_id: nil,
        delete: false
      }
    )
    |> Repo.all()
  end

  defp pay_slip_notes(type) do
    from(note in subquery(salary_note_query()),
      where: note.salary_type_type == ^type
    )
  end

  def get_recal_pay_slip(id, com, user) do
    ps = get_pay_slip!(id, com)

    {add, bon, ded, con, lea, adv} =
      generate_pay_slip_children(%{id: ps.employee_id}, ps.pay_month, ps.pay_year, com, user)

    add =
      Enum.reject(add, fn a ->
        !is_nil(Enum.find_index(ps.additions, fn n -> a._id == n._id end))
      end)
      |> Enum.map(fn x -> Map.merge(x, %{id: x._id, __struct__: SalaryNote}) end)

    bon =
      Enum.reject(bon, fn a ->
        !is_nil(Enum.find_index(ps.bonuses, fn n -> a._id == n._id end))
      end)
      |> Enum.map(fn x -> Map.merge(x, %{id: x._id, __struct__: SalaryNote}) end)

    ded =
      Enum.reject(ded, fn a ->
        !is_nil(Enum.find_index(ps.deductions, fn n -> a._id == n._id end))
      end)
      |> Enum.reject(fn a ->
        !is_nil(
          Enum.find_index(ps.deductions, fn n ->
            a.note_no == "...new..." and a.salary_type_id == n.salary_type_id
          end)
        )
      end)
      |> Enum.map(fn x -> Map.merge(x, %{id: x._id, __struct__: SalaryNote}) end)

    con =
      Enum.reject(con, fn a ->
        !is_nil(Enum.find_index(ps.contributions, fn n -> a._id == n._id end))
      end)
      |> Enum.reject(fn a ->
        !is_nil(
          Enum.find_index(ps.contributions, fn n ->
            a.note_no == "...new..." and a.salary_type_id == n.salary_type_id
          end)
        )
      end)
      |> Enum.map(fn x -> Map.merge(x, %{id: x._id, __struct__: SalaryNote}) end)

    lea =
      Enum.reject(lea, fn a ->
        !is_nil(Enum.find_index(ps.leaves, fn n -> a._id == n._id end))
      end)
      |> Enum.map(fn x -> Map.merge(x, %{id: x._id, __struct__: SalaryNote}) end)

    adv =
      Enum.reject(adv, fn a ->
        !is_nil(Enum.find_index(ps.advances, fn n -> a._id == n.id end))
      end)
      |> Enum.map(fn x -> Map.merge(x, %{id: x._id, __struct__: Advance}) end)

    ps_add = ps.additions ++ add
    ps_bon = ps.bonuses ++ bon
    ps_ded = ps.deductions ++ ded
    ps_con = ps.contributions ++ con
    ps_lea = ps.leaves ++ lea
    ps_adv = ps.advances ++ adv

    Map.merge(ps, %{
      additions: ps_add,
      bonuses: ps_bon,
      deductions: ps_ded,
      contributions: ps_con,
      leaves: ps_lea,
      advances: ps_adv
    })
  end

  def get_pay_slip!(id, com) do
    from(ps in PaySlip,
      join: emp in Employee,
      on: emp.id == ps.employee_id,
      join: ac in Account,
      on: ac.id == ps.funds_account_id,
      preload: [additions: ^pay_slip_notes("Addition")],
      preload: [bonuses: ^pay_slip_notes("Bonus")],
      preload: [deductions: ^pay_slip_notes("Deduction")],
      preload: [contributions: ^pay_slip_notes("Contribution")],
      preload: [leaves: ^pay_slip_notes("LeaveTaken")],
      preload: [advances: ^advance_query()],
      where: ps.company_id == ^com.id,
      where: ps.id == ^id,
      select: ps,
      select_merge: %{
        employee_name: emp.name,
        funds_account_name: ac.name
      }
    )
    |> Repo.one!()
  end

  def get_print_pay_slips(ids, com) do
    from(ps in PaySlip,
      preload: [additions: ^pay_slip_notes("Addition")],
      preload: [bonuses: ^pay_slip_notes("Bonus")],
      preload: [deductions: ^pay_slip_notes("Deduction")],
      preload: [contributions: ^pay_slip_notes("Contribution")],
      preload: [leaves: ^pay_slip_notes("LeaveTaken")],
      preload: [advances: ^advance_query()],
      preload: [:employee, :funds_account],
      where: ps.company_id == ^com.id,
      where: ps.id in ^ids,
      select: ps
    )
    |> Repo.all()
    |> Enum.map(fn x -> PaySlip.compute_struct_fields(x) end)
    |> Enum.map(fn x ->
      Map.merge(x, %{issued_by: last_log_record_for("pay_slips", x.id, x.company_id)})
    end)
  end

  def get_pay_slip_by_period(emp, mth, yr, com) do
    from(ps in PaySlip,
      join: e in Employee,
      on: ps.employee_id == e.id,
      join: c in Company,
      on: c.id == ps.company_id,
      on: c.id == ^com.id,
      on: e.id == ^emp.id,
      where: ps.pay_month == ^mth,
      where: ps.pay_year == ^yr
    )
    |> Repo.one()
  end

  def create_pay_slip(attrs, com, user) do
    case can?(user, :create_pay_slip, com) do
      true ->
        Multi.new()
        |> create_pay_slip_multi(prepare_pay_slip(attrs), attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  end

  def update_pay_slip(%PaySlip{} = ps, attrs, com, user) do
    case can?(user, :update_pay_slip, com) do
      true ->
        Multi.new()
        |> update_pay_slip_multi(ps, prepare_pay_slip(attrs), attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  rescue
    e in Postgrex.Error ->
      {:sql_error, e.postgres.message}
  end

  defp prepare_pay_slip(attrs) do
    add =
      (attrs["additions"] || %{}) |> Map.to_list() |> Enum.map(fn {k, v} -> {"#{k}add", v} end)

    bon =
      (attrs["bonuses"] || %{}) |> Map.to_list() |> Enum.map(fn {k, v} -> {"#{k}bon", v} end)

    ded =
      (attrs["deductions"] || %{}) |> Map.to_list() |> Enum.map(fn {k, v} -> {"#{k}ded", v} end)

    adv = (attrs["advances"] || %{}) |> Map.to_list() |> Enum.map(fn {k, v} -> {"#{k}adv", v} end)

    pay_amount = attrs["pay_slip_amount"]

    con =
      (attrs["contributions"] || %{})
      |> Map.to_list()
      |> Enum.map(fn {k, v} -> {"#{k}con", v} end)

    lea =
      (attrs["leaves"] || %{})
      |> Map.to_list()
      |> Enum.map(fn {k, v} -> {"#{k}lea", v} end)

    pay =
      attrs
      |> Map.reject(fn {k, _v} -> k == "additions" end)
      |> Map.reject(fn {k, _v} -> k == "bonuses" end)
      |> Map.reject(fn {k, _v} -> k == "deductions" end)
      |> Map.reject(fn {k, _v} -> k == "advances" end)
      |> Map.reject(fn {k, _v} -> k == "contributions" end)
      |> Map.reject(fn {k, _v} -> k == "leaves" end)

    {add ++ bon ++ ded ++ con ++ lea, adv, pay, pay_amount}
  end

  defp update_pay_slip_multi(multi, ps, {sns, adv, pay, pay_amount}, attrs, com, user) do
    name = :update_pay_slip

    multi
    |> Multi.update(
      name,
      PaySlip.changeset_no_compute(ps, Map.merge(pay, %{"company_id" => com.id}))
    )
    |> Multi.delete_all(
      :delete_transaction,
      from(txn in Transaction,
        where: txn.doc_type == "PaySlip",
        where: txn.doc_no == ^ps.slip_no,
        where: txn.company_id == ^com.id
      )
    )
    |> Sys.insert_log_for(name, attrs, com, user)
    |> process_notes(sns, name, com, user)
    |> process_advances(adv, name, com, user)
    |> create_pay_slip_transactions(name, pay_amount, com, user)
  end

  defp create_pay_slip_multi(multi, {sns, adv, pay, pay_amount}, attrs, com, user) do
    gapless_name = String.to_atom("update_gapless_doc_ps_#{gen_temp_id()}")
    name = :create_pay_slip

    multi
    |> get_gapless_doc_id(gapless_name, "PaySlip", "PS", com)
    |> Multi.insert(name, fn %{^gapless_name => doc} ->
      StdInterface.changeset(PaySlip, %PaySlip{}, Map.merge(pay, %{"slip_no" => doc}), com)
    end)
    |> process_notes(sns, name, com, user)
    |> process_advances(adv, name, com, user)
    |> Multi.insert("#{name}_log", fn %{^name => entity} ->
      Sys.log_changeset(
        name,
        entity,
        Map.merge(attrs, %{"slip_no" => entity.slip_no}),
        com,
        user
      )
    end)
    |> create_pay_slip_transactions(name, pay_amount, com, user)
  end

  defp process_notes(multi, notes, name, com, user) do
    existing_notes = Enum.filter(notes, fn {_, a} -> a["_id"] != "" end)

    new_notes =
      notes
      |> Enum.filter(fn {_, a} -> a["_id"] == "" end)
      |> Enum.reject(fn {_, a} -> String.to_float(a["amount"]) == 0 end)

    process_existing_notes(multi, existing_notes, name, com, user)
    |> process_new_notes(new_notes, name, com, user)
  end

  defp process_new_notes(multi, notes, name, com, user) do
    Multi.merge(
      multi,
      fn %{^name => ps} ->
        Enum.reduce(notes, Multi.new(), fn {_, note}, reduce_multi ->
          HR.create_salary_note_multi(
            reduce_multi,
            note |> Map.merge(%{"pay_slip_id" => ps.id, "pay_slip_no" => ps.slip_no}),
            com,
            user,
            :changeset_on_payslip,
            "pay_slip_create_salary_note_#{gen_temp_id()}" |> String.to_atom()
          )
        end)
      end
    )
  end

  defp process_existing_notes(multi, notes, name, com, user) do
    Multi.merge(
      multi,
      fn %{^name => ps} ->
        Enum.reduce(notes, Multi.new(), fn {_, note}, reduce_multi ->
          HR.update_salary_note_multi(
            reduce_multi,
            HR.get_salary_note!(note["_id"], com, user),
            note |> Map.merge(%{"pay_slip_id" => ps.id, "pay_slip_no" => ps.slip_no}),
            com,
            user,
            :changeset_on_payslip,
            "pay_slip_update_salary_note_#{gen_temp_id()}" |> String.to_atom()
          )
        end)
      end
    )
  end

  defp process_advances(multi, advs_attrs, name, com, user) do
    adv_ids = Enum.map(advs_attrs, fn {_, a} -> a["_id"] end)

    multi
    |> Multi.update_all(
      :update_all_advance,
      fn %{^name => slip} ->
        from(a in Advance, where: a.id in ^adv_ids, update: [set: [pay_slip_id: ^slip.id]])
      end,
      []
    )
    |> Multi.insert_all(:insert_updated_advance_log, Log, fn %{^name => slip} ->
      advs_attrs
      |> Enum.map(fn {_, a} ->
        adv = HR.get_advance!(a["_id"], com, user)

        a =
          Map.merge(a, %{
            "employee_name" => adv.employee_name,
            "funds_account_name" => adv.funds_account_name,
            "pay_slip_no" => slip.slip_no
          })

        Sys.log_attrs(
          :pay_slip_update_advance,
          adv,
          a,
          com,
          user
        )
        |> Map.merge(%{inserted_at: Timex.now() |> DateTime.truncate(:second)})
      end)
    end)
  end

  defp create_pay_slip_transactions(multi, name, pay_slip_amount, com, user) do
    sal_paya_id = Accounting.get_account_by_name("Salaries and Wages Payable", com, user).id

    multi
    |> Multi.insert_all(
      "create_db_transactions" |> String.to_atom(),
      Transaction,
      fn %{^name => slp} ->
        [
          %{
            doc_type: "PaySlip",
            doc_no: slp.slip_no,
            doc_id: slp.id,
            doc_date: slp.slip_date,
            account_id: sal_paya_id,
            company_id: com.id,
            amount: Decimal.new(pay_slip_amount),
            particulars: "Salary #{slp.pay_month}/#{slp.pay_year} to #{slp.employee_name}",
            inserted_at: Timex.now() |> DateTime.truncate(:second)
          },
          %{
            doc_type: "PaySlip",
            doc_no: slp.slip_no,
            doc_id: slp.id,
            doc_date: slp.slip_date,
            account_id: slp.funds_account_id,
            company_id: com.id,
            amount: Decimal.negate(pay_slip_amount),
            particulars: "Salary #{slp.pay_month}/#{slp.pay_year} to #{slp.employee_name}",
            inserted_at: Timex.now() |> DateTime.truncate(:second)
          }
        ]
      end
    )
  end
end
