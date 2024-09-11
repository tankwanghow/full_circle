defmodule FullCircle.HR.TimeAttend do
  use FullCircle.Schema
  import Ecto.Changeset
  import Ecto.Query, warn: false
  import FullCircle.Helpers

  schema "time_attendences" do
    field(:flag, :string)
    field(:input_medium, :string)
    field(:punch_time, :utc_datetime)
    field(:gps_long, :float)
    field(:gps_lat, :float)
    field(:status, :string, default: "Draft")

    field(:employee_name, :string, virtual: true)
    field(:email, :string, virtual: true)
    field(:punch_time_local, :naive_datetime, virtual: true)

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
      :status,
      :user_id
    ])
    |> validate_required([
      :flag,
      :input_medium,
      :punch_time_local,
      :company_id,
      :employee_id,
      :employee_name,
      :status,
      :user_id
    ])
    |> punch_time_to_utc()
    |> validate_date(:punch_time_local, days_before: 40)
    |> validate_date(:punch_time_local, days_after: 0)
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
      :gps_long,
      :gps_lat,
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

  def punch_time_to_local_tz(ta, com) do
    ta |> Map.merge(%{punch_time_local: ta.punch_time |> Timex.to_datetime(com.timezone)})
  end

  defp punch_time_to_utc(cs) do
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
    diff = if(!is_nil(lpr), do: Timex.diff(punch_time, lpr.punch_time, :minute), else: 0)

    cond do
      is_nil(lpr) and String.contains?(flag, "OUT") ->
        add_error(cs, :flag, "NO 'IN' RECORD!!")

      is_nil(lpr) and String.contains?(flag, "IN") ->
        put_change(cs, :flag, mold_punch_time_flag(nil, flag))

      extract_flag_inout(lpr.flag) == flag ->
        add_error(cs, :flag, "DOUBLE #{flag}")

      diff < 3 ->
        add_error(cs, :punch_time, "need 3 minute in between punches")

      diff / 60 > 12 and !String.contains?(flag, "IN") ->
        add_error(cs, :punch_time, "more than 12 hours")

      diff / 60 > 12 and String.contains?(flag, "IN") ->
        put_change(cs, :flag, mold_punch_time_flag(lpr.flag, flag))

      diff >= 3 and diff / 60 <= 12 ->
        put_change(cs, :flag, mold_punch_time_flag(lpr.flag, flag))
    end
  end

  defp mold_punch_time_flag(lpr, flag) do
    if is_nil(lpr) do
      "1_IN_1"
    else
      cond do
        lpr == "1_IN_1" and flag == "OUT" -> "1_OUT_1"
        lpr == "2_IN_2" and flag == "OUT" -> "2_OUT_2"
        lpr == "3_IN_3" and flag == "OUT" -> "3_OUT_3"
        lpr == "1_OUT_1" and flag == "IN" -> "2_IN_2"
        lpr == "2_OUT_2" and flag == "IN" -> "3_IN_3"
        lpr == "3_OUT_3" and flag == "IN" -> "1_IN_1"
      end
    end
  end

  defp extract_flag_inout(flag) do
    Regex.scan(~r/IN|OUT/, flag) |> List.flatten() |> Enum.at(0)
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
