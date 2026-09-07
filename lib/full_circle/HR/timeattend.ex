defmodule FullCircle.HR.TimeAttend do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers

  schema "time_attendences" do
    field(:flag, :string)
    field(:input_medium, :string)
    field(:punch_time, :utc_datetime)
    field(:gps_long, :float)
    field(:gps_lat, :float)
    field(:status, :string, default: "Draft")
    field(:photo_path, :string)
    field(:client_id, :string)
    belongs_to(:punch_device, FullCircle.PunchGate.PunchDevice)

    field(:employee_name, :string, virtual: true)
    field(:email, :string, virtual: true)
    field(:punch_time_local, :naive_datetime, virtual: true)

    belongs_to(:company, FullCircle.Sys.Company)
    belongs_to(:employee, FullCircle.HR.Employee)
    belongs_to(:user, FullCircle.UserAccounts.User)
    timestamps(type: :utc_datetime)
  end

  def finger_print_log_changeset(st, attrs) do
    st
    |> cast(attrs, [
      :flag,
      :input_medium,
      :company_id,
      :employee_id,
      :employee_name,
      :punch_time_local,
      :punch_time,
      :status,
      :user_id
    ])
    |> validate_required([
      :flag,
      :input_medium,
      :punch_time_local,
      :punch_time,
      :company_id,
      :employee_id,
      :employee_name,
      :status,
      :user_id
    ])
  end

  def changeset_gate(st, attrs) do
    st
    |> cast(attrs, [
      :flag,
      :input_medium,
      :punch_time,
      :company_id,
      :employee_id,
      :punch_device_id,
      :client_id,
      :status
    ])
    |> validate_required([
      :flag,
      :input_medium,
      :punch_time,
      :company_id,
      :employee_id,
      :punch_device_id,
      :client_id
    ])
    |> unique_constraint(:client_id, name: :time_attendences_punch_device_id_client_id_index)
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
    # No days_before cap: historical attendance (e.g. imported fingerprint months)
    # must be editable. Editing is instead frozen once a PaySlip exists for the
    # employee/month — enforced in HR.create/update/delete_time_attendence.
    |> validate_date(:punch_time_local, days_after: 0)
    |> validate_id(:employee_name, :employee_id)
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
end
