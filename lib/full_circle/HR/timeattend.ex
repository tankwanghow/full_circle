defmodule FullCircle.HR.TimeAttend do
  use FullCircle.Schema
  import Ecto.Changeset
  import Ecto.Query, warn: false
  import FullCircle.Helpers

  schema "time_attendences" do
    field(:flag, :string)
    field(:input_medium, :string)
    field(:punch_time, :utc_datetime)
    field(:marker, :string)

    field(:employee_name, :string, virtual: true)
    field(:email, :string, virtual: true)
    field(:punch_time_local, :utc_datetime, virtual: true)

    belongs_to(:company, FullCircle.Sys.Company)
    belongs_to(:employee, FullCircle.HR.Employee)
    belongs_to(:user, FullCircle.UserAccounts.User)
    timestamps(type: :utc_datetime)
  end

  @doc false
  def data_entry_changeset(st, attrs) do
    st
    |> cast(attrs, [
      :flag,
      :input_medium,
      :company_id,
      :employee_id,
      :employee_name,
      :punch_time_local,
      :user_id
    ])
    |> validate_required([
      :flag,
      :input_medium,
      :punch_time_local,
      :company_id,
      :employee_id,
      :employee_name,
      :user_id
    ])
    |> fill_punch_time()
    |> validate_id(:employee_name, :employee_id)
  end

  @doc false
  def changeset(st, attrs) do
    st
    |> cast(attrs, [
      :flag,
      :input_medium,
      :punch_time,
      :company_id,
      :employee_id,
      :user_id
    ])
    |> validate_required([
      :flag,
      :input_medium,
      :punch_time,
      :company_id,
      :employee_id,
      :user_id
    ])
    |> validate_punch_time()
  end

  def set_punch_time_local(ta, com) do
    ta |> Map.merge(%{punch_time_local: ta.punch_time |> Timex.to_datetime(com.timezone)})
  end

  defp fill_punch_time(cs) do
    pt = fetch_field!(cs, :punch_time_local)

    if !is_nil(pt) do
      tz = FullCircle.Sys.get_company!(fetch_field!(cs, :company_id)).timezone
      pt = pt |> Timex.to_naive_datetime() |> Timex.to_datetime(tz) |> Timex.to_datetime(:utc)
      put_change(cs, :punch_time, pt)
    else
      cs
    end
  end

  defp validate_punch_time(cs) do
    flag = fetch_field!(cs, :flag)
    emp_id = fetch_field!(cs, :employee_id)
    com_id = fetch_field!(cs, :company_id)
    punch_time = fetch_field!(cs, :punch_time)
    id = fetch_field!(cs, :id)

    lpr = last_punch_record(id, emp_id, com_id)

    cond do
      is_nil(lpr) and flag == "OUT" ->
        add_error(cs, :flag, "NO IN RECORD!!")

      is_nil(lpr) ->
        cs

      lpr.flag == flag ->
        add_error(cs, :flag, "DOUBLE #{flag}")

      Timex.compare(punch_time, lpr.punch_time, :minute) == 1 ->
        cs

      Timex.compare(punch_time, lpr.punch_time, :minute) != 1 ->
        add_error(
          cs,
          :punch_time,
          "#{FullCircleWeb.Helpers.format_datetime(lpr.punch_time, FullCircle.Sys.get_company!(com_id))} Punched #{lpr.flag}"
        )
    end
  end

  def last_punch_record(id, emp_id, com_id) do
    qry =
      from(ta in FullCircle.HR.TimeAttend,
        where: ta.company_id == ^com_id,
        order_by: ta.punch_time
      )

    qry =
      if !is_nil(emp_id) do
        from q in qry, where: q.employee_id == ^emp_id
      else
        from q in qry, where: false
      end

    qry =
      if !is_nil(id) do
        from q in qry, where: q.id != ^id
      else
        qry
      end

    qry |> last() |> FullCircle.Repo.one()
  end
end
