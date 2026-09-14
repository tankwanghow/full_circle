defmodule FullCircle.PunchGate.PunchIngestLog do
  @moduledoc """
  Append-only operational log of every gate POST the server can attribute to a
  company — accepted, replayed, duplicate, rejected, or refused with a 401
  because the device was revoked.

  This is **not** an attendance register; `time_attendences` stays the payroll
  source of truth. Rows are written best-effort after the punch is already
  decided, so a bad row here can never cost a punch. `id` and `inserted_at` are
  cast on purpose: the writer generates both up front so the JPEG filename and
  its `yyyy/mm` folder are known before the row exists.

  `inserted_at` is microsecond precision (like `UserAccounts.User`), not the
  second precision the rest of this app defaults to. A queue drain writes many
  rows inside one second, and at second precision `order_by: [desc: inserted_at]`
  has no defined order among them: "newest first" renders wrong, offset paging
  can skip and repeat rows, and order assertions go flaky.
  """
  use FullCircle.Schema
  import Ecto.Changeset

  @outcomes ~w(accepted replayed duplicate rejected)
  @reasons ~w(not_found inactive too_large missing_photo future invalid revoked)

  schema "punch_ingest_logs" do
    field :employee_id_raw, :string
    field :client_id, :string
    field :punched_at, :utc_datetime
    field :outcome, :string
    field :reason, :string
    field :http_status, :integer
    field :photo_path, :string

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :punch_device, FullCircle.PunchGate.PunchDevice
    belongs_to :employee, FullCircle.HR.Employee
    belongs_to :time_attendence, FullCircle.HR.TimeAttend

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def outcomes, do: @outcomes
  def reasons, do: @reasons

  def changeset(log, attrs) do
    log
    |> cast(attrs, [
      :id,
      :inserted_at,
      :company_id,
      :punch_device_id,
      :employee_id,
      :employee_id_raw,
      :time_attendence_id,
      :client_id,
      :punched_at,
      :outcome,
      :reason,
      :http_status,
      :photo_path
    ])
    |> validate_required([:company_id, :outcome, :http_status])
  end
end
