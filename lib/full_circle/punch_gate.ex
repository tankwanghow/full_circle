defmodule FullCircle.PunchGate do
  import Ecto.Query, warn: false
  require Logger
  alias FullCircle.Repo
  alias FullCircle.PunchGate.{PunchDevice, PunchIngestLog}
  alias FullCircle.Authorization
  alias FullCircle.HR.{TimeAttend, Employee}

  @dup_seconds 180
  @future_leeway_seconds 120
  @max_photo_bytes 300_000
  @prune_batch 500

  def hash_token(plain) when is_binary(plain) do
    :crypto.hash(:sha256, plain) |> Base.encode16(case: :lower)
  end

  def badge_payload(%{id: id}), do: "fcqa:#{id}"

  def parse_badge_payload("fcqa:" <> id), do: {:ok, id}

  def parse_badge_payload(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  @doc """
  The HTTP status the gate API answers for an ingest result.

  Single source of truth: `PunchAttendanceController` sends it and
  `punch_ingest_logs.http_status` stores it, so the two cannot drift.
  """
  def http_status_for(:accepted), do: 201
  def http_status_for(:revoked), do: 401
  def http_status_for(:not_found), do: 404
  def http_status_for(:duplicate), do: 409
  def http_status_for(:too_large), do: 413
  def http_status_for(_), do: 422

  def create_device(name, company, user) do
    case Authorization.can?(user, :manage_punch_device, company) do
      true ->
        plain = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

        %PunchDevice{}
        |> PunchDevice.changeset(%{
          name: name,
          token_hash: hash_token(plain),
          company_id: company.id,
          paired_by_user_id: user.id
        })
        |> Repo.insert()
        |> case do
          {:ok, device} -> {:ok, {device, plain}}
          {:error, cs} -> {:error, cs}
        end

      false ->
        :not_authorise
    end
  end

  def revoke_device(%PunchDevice{} = device, company, user) do
    case Authorization.can?(user, :manage_punch_device, company) and
           device.company_id == company.id do
      true ->
        device
        |> PunchDevice.changeset(%{
          revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.update()

      false ->
        :not_authorise
    end
  end

  @doc """
  Resolves a device Bearer token.

  Returns `{:revoked, device}` rather than `nil` for a token whose device was
  revoked: that POST is still attributable to a company, and it is a *silent*
  punch loss (the APK drops 4xx), so it is worth a `punch_ingest_logs` row.
  A token matching no row stays anonymous and is never logged.
  """
  def authenticate_device(plain) when is_binary(plain) do
    from(d in PunchDevice,
      where: d.token_hash == ^hash_token(plain),
      preload: [:company]
    )
    |> Repo.one()
    |> case do
      nil -> :error
      %PunchDevice{revoked_at: nil} = device -> {:ok, device}
      %PunchDevice{} = device -> {:revoked, device}
    end
  end

  def get_active_device_by_token(plain) when is_binary(plain) do
    case authenticate_device(plain) do
      {:ok, device} -> device
      _ -> nil
    end
  end

  def list_devices(company, user) do
    case Authorization.can?(user, :manage_punch_device, company) do
      true ->
        from(d in PunchDevice,
          where: d.company_id == ^company.id,
          where: is_nil(d.revoked_at),
          order_by: [asc: d.name]
        )
        |> Repo.all()

      false ->
        :not_authorise
    end
  end

  def ingest_punch(%PunchDevice{} = device, attrs) do
    device = Repo.preload(device, :company)
    company = device.company
    employee_id = to_string(attrs["employee_id"] || attrs[:employee_id] || "")
    client_id = attrs["client_id"] || attrs[:client_id]
    raw_punched_at = attrs["punched_at"] || attrs[:punched_at]
    photo = attrs["photo"] || attrs[:photo]

    result =
      with :ok <- validate_photo(photo),
           {:ok, punched_at} <- parse_punched_at(raw_punched_at),
           :ok <- validate_not_future(punched_at),
           %Employee{} = emp <- get_company_employee(employee_id, company.id),
           :ok <- validate_active(emp) do
        case existing_client(device.id, client_id) do
          %TimeAttend{} = ta ->
            {:replayed, ta}

          nil ->
            with :ok <- reject_duplicate(emp.id, company.id, punched_at) do
              insert_punch(device, emp, company, punched_at, client_id, photo)
            else
              {:error, reason} -> {:error, reason}
            end
        end
      else
        {:error, reason} -> {:error, reason}
      end

    log_ingest(
      device,
      %{
        employee_id_raw: employee_id,
        client_id: client_id,
        punched_at: raw_punched_at,
        photo: photo
      },
      result
    )

    strip_log_tag(result)
  end

  # The logger wants more than the caller does. Strip the extra back off so the
  # public contract stays {:ok, ta} | {:error, atom}.
  defp strip_log_tag({:replayed, ta}), do: {:ok, ta}
  defp strip_log_tag({:error, reason, _employee_id}), do: {:error, reason}
  defp strip_log_tag(other), do: other

  def photo_abs_path(company_id, %TimeAttend{id: id, punch_time: pt}) do
    date = DateTime.to_date(pt)

    Path.join([
      Application.get_env(:full_circle, :uploads_dir),
      "#{company_id}",
      "punch_photos",
      "#{date.year}",
      date.month |> Integer.to_string() |> String.pad_leading(2, "0"),
      "#{id}.jpg"
    ])
  end

  @doc """
  Where a log JPEG lives. The folder is `inserted_at`'s UTC year/month — a
  folder, not a business date, so no timezone conversion is wanted here.
  """
  def ingest_log_photo_abs_path(company_id, log_id, %DateTime{} = at) do
    Path.join([
      Application.get_env(:full_circle, :uploads_dir),
      "#{company_id}",
      "punch_ingest_logs",
      "#{at.year}",
      at.month |> Integer.to_string() |> String.pad_leading(2, "0"),
      "#{log_id}.jpg"
    ])
  end

  @doc """
  Deletes punch photos captured before `cutoff`, keeping the attendance rows.

  The file is removed **before** `photo_path` is cleared. If that is interrupted
  the row points at a missing file, which `PunchPhotoController` already answers
  with a 404, and the next run finishes the job — a missing file counts as
  success. The reverse order would orphan the file permanently and never reclaim
  the disk this exists to reclaim.

  Options: `:dry_run` (report what would go, change nothing) and `:batch`.
  """
  def prune_photos_before(%DateTime{} = cutoff, opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    batch = Keyword.get(opts, :batch, @prune_batch)
    uploads = Application.get_env(:full_circle, :uploads_dir)

    {:ok, prune_batches(cutoff, batch, dry_run?, uploads, 0)}
  end

  defp prune_batches(cutoff, batch, dry_run?, uploads, done) do
    rows =
      from(ta in TimeAttend,
        where: not is_nil(ta.photo_path),
        where: ta.punch_time < ^cutoff,
        order_by: [asc: ta.punch_time],
        limit: ^batch,
        select: %{id: ta.id, photo_path: ta.photo_path}
      )
      |> Repo.all()

    cond do
      rows == [] ->
        done

      dry_run? ->
        # Nothing is written, so paging would loop forever on the same rows.
        done + length(rows) + count_remaining(cutoff, length(rows))

      true ->
        Enum.each(rows, fn row ->
          uploads |> Path.join(row.photo_path) |> File.rm()

          from(ta in TimeAttend, where: ta.id == ^row.id)
          |> Repo.update_all(set: [photo_path: nil])
        end)

        prune_batches(cutoff, batch, dry_run?, uploads, done + length(rows))
    end
  end

  defp count_remaining(cutoff, seen) do
    total =
      from(ta in TimeAttend,
        where: not is_nil(ta.photo_path),
        where: ta.punch_time < ^cutoff,
        select: count(ta.id)
      )
      |> Repo.one()

    max(total - seen, 0)
  end

  @doc """
  Deletes `punch_ingest_logs` received before `cutoff`, file then row.

  The file is removed first: if that is interrupted the row points at a missing
  file, which the photo controller already answers with a 404, and the next run
  finishes the job. The reverse order would orphan the file forever.

  Options: `:dry_run` (report what would go, change nothing) and `:batch`.
  """
  def prune_ingest_logs_before(%DateTime{} = cutoff, opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    batch = Keyword.get(opts, :batch, @prune_batch)
    uploads = Application.get_env(:full_circle, :uploads_dir)

    {:ok, prune_log_batches(cutoff, batch, dry_run?, uploads, 0)}
  end

  defp prune_log_batches(cutoff, batch, dry_run?, uploads, done) do
    rows =
      from(l in PunchIngestLog,
        where: l.inserted_at < ^cutoff,
        order_by: [asc: l.inserted_at],
        limit: ^batch,
        select: %{id: l.id, photo_path: l.photo_path}
      )
      |> Repo.all()

    cond do
      rows == [] ->
        done

      dry_run? ->
        # Nothing is written, so paging would loop forever on the same rows.
        done + length(rows) + count_remaining_logs(cutoff, length(rows))

      true ->
        Enum.each(rows, fn row ->
          if row.photo_path, do: uploads |> Path.join(row.photo_path) |> File.rm()
          from(l in PunchIngestLog, where: l.id == ^row.id) |> Repo.delete_all()
        end)

        prune_log_batches(cutoff, batch, dry_run?, uploads, done + length(rows))
    end
  end

  defp count_remaining_logs(cutoff, seen) do
    total =
      from(l in PunchIngestLog,
        where: l.inserted_at < ^cutoff,
        select: count(l.id)
      )
      |> Repo.one()

    max(total - seen, 0)
  end

  defp insert_punch(device, emp, company, punched_at, client_id, photo) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(
      :ta,
      TimeAttend.changeset_gate(%TimeAttend{}, %{
        employee_id: emp.id,
        company_id: company.id,
        punch_device_id: device.id,
        punch_time: punched_at,
        input_medium: "QRGate",
        flag: "1_IN_1",
        status: "Draft",
        client_id: client_id
      })
    )
    |> Ecto.Multi.run(:photo, fn _repo, %{ta: ta} ->
      abs = photo_abs_path(company.id, ta)
      File.mkdir_p!(Path.dirname(abs))
      File.cp!(photo_src(photo), abs)
      rel = Path.relative_to(abs, Application.get_env(:full_circle, :uploads_dir))
      ta |> Ecto.Changeset.change(%{photo_path: rel}) |> Repo.update()
    end)
    |> Ecto.Multi.run(:flags, fn _repo, %{photo: ta} ->
      {:ok, ta} = FullCircle.HR.reassign_punch(ta, company)
      {:ok, ta}
    end)
    |> Ecto.Multi.update(:seen, fn _ ->
      PunchDevice.changeset(device, %{
        last_seen_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{flags: ta}} ->
        {:ok, Repo.preload(ta, :employee)}

      {:error, :ta, %Ecto.Changeset{} = cs, _} ->
        resolve_client_conflict(cs, device.id, client_id, emp.id)

      {:error, _, reason, _} when is_atom(reason) ->
        {:error, reason, emp.id}

      {:error, _, _reason, _} ->
        {:error, :invalid, emp.id}
    end
  end

  @doc false
  # Public only so the unique-index race can be tested without two connections
  # and a controlled interleave.
  def resolve_client_conflict(%Ecto.Changeset{} = cs, device_id, client_id, employee_id) do
    unique? =
      case Keyword.get(cs.errors, :client_id) do
        {_msg, opts} -> opts[:constraint] == :unique
        _ -> false
      end

    if unique? do
      case existing_client(device_id, client_id) do
        %TimeAttend{} = ta -> {:replayed, Repo.preload(ta, :employee)}
        nil -> {:error, :invalid, employee_id}
      end
    else
      {:error, :invalid, employee_id}
    end
  end

  defp photo_src(%Plug.Upload{path: p}), do: p
  defp photo_src(%{path: p}), do: p

  defp validate_photo(nil), do: {:error, :missing_photo}

  defp validate_photo(photo) do
    src = photo_src(photo)

    case File.stat(src) do
      {:ok, %{size: n}} when n > 0 and n <= @max_photo_bytes -> :ok
      {:ok, %{size: n}} when n > @max_photo_bytes -> {:error, :too_large}
      _ -> {:error, :missing_photo}
    end
  end

  defp parse_punched_at(%DateTime{} = dt), do: {:ok, DateTime.truncate(dt, :second)}

  defp parse_punched_at(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> {:ok, DateTime.truncate(dt, :second)}
      _ -> {:error, :invalid}
    end
  end

  defp parse_punched_at(_), do: {:error, :invalid}

  defp validate_not_future(%DateTime{} = dt) do
    if DateTime.diff(dt, DateTime.utc_now()) > @future_leeway_seconds,
      do: {:error, :future},
      else: :ok
  end

  defp get_company_employee(id, company_id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Repo.get_by(Employee, id: uuid, company_id: company_id) || {:error, :not_found}

      :error ->
        {:error, :not_found}
    end
  end

  defp validate_active(%Employee{status: "Active"}), do: :ok
  defp validate_active(_), do: {:error, :inactive}

  defp reject_duplicate(emp_id, company_id, punched_at) do
    from_t = DateTime.add(punched_at, -@dup_seconds, :second)
    to_t = DateTime.add(punched_at, @dup_seconds, :second)

    exists? =
      from(ta in TimeAttend,
        where: ta.employee_id == ^emp_id,
        where: ta.company_id == ^company_id,
        where: ta.punch_time >= ^from_t and ta.punch_time <= ^to_t
      )
      |> Repo.exists?()

    if exists?, do: {:error, :duplicate}, else: :ok
  end

  defp existing_client(_device_id, nil), do: nil

  defp existing_client(device_id, client_id) do
    Repo.get_by(TimeAttend, punch_device_id: device_id, client_id: client_id)
  end

  # ── Ingest logging ─────────────────────────────────────────────────
  # Best effort, always after the punch is decided. Nothing in here may
  # change what ingest_punch/2 returns or what the controller sends.

  @raw_field_limit 64

  # The rescue stays on this whole function, exactly as in Task 2 — it does not
  # move down onto the insert. Building the attrs runs outcome_and_reason/1 (a
  # pattern match on a result shape), log_status_atom/2 (String.to_existing_atom),
  # log_employee_id/3 (a query) and truncate_field/1 (to_string on unvalidated
  # client values). A raise in any of them must not turn a decided punch into a
  # 500 that the phone will retry.
  defp log_ingest(%PunchDevice{} = device, info, result) do
    {outcome, reason} = outcome_and_reason(result)
    id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    photo_path =
      if log_photo?(outcome, reason),
        do: copy_log_photo(device.company_id, id, now, info.photo),
        else: nil

    attrs = %{
      id: id,
      inserted_at: now,
      company_id: device.company_id,
      punch_device_id: device.id,
      employee_id: log_employee_id(result, info.employee_id_raw, device.company_id),
      employee_id_raw: truncate_field(info.employee_id_raw),
      time_attendence_id: log_time_attendence_id(result),
      client_id: truncate_field(info.client_id),
      punched_at: parsed_or_nil(info.punched_at),
      outcome: outcome,
      reason: reason,
      http_status: http_status_for(log_status_atom(outcome, reason)),
      photo_path: photo_path
    }

    case insert_ingest_log(attrs) do
      {:ok, log} ->
        {:ok, log}

      :error ->
        # The row is what makes the file findable; without one it is garbage.
        if photo_path, do: File.rm(Path.join(uploads_dir(), photo_path))
        :error
    end
  rescue
    e ->
      # A raise after the JPEG was copied leaves that file behind. It is the
      # same class of orphan as a deleted company's folder, and not worth a
      # second cleanup path; losing the HTTP contract would be.
      Logger.error("punch ingest log raised: #{Exception.message(e)}")
      :error
  end

  defp uploads_dir, do: Application.get_env(:full_circle, :uploads_dir)

  # validate_photo/1 is the first clause of the ingest `with`, so anything that
  # gets past it has a usable JPEG. Accepted and replayed faces already live on
  # time_attendences for 24 months and are never copied here; revoked is logged
  # from the auth plug, before any photo handling.
  defp log_photo?(outcome, _reason) when outcome in ["accepted", "replayed"], do: false

  defp log_photo?(_outcome, reason) when reason in ["missing_photo", "too_large", "revoked"],
    do: false

  defp log_photo?(_outcome, _reason), do: true

  defp copy_log_photo(_company_id, _id, _now, nil), do: nil

  defp copy_log_photo(company_id, id, now, photo) do
    abs = ingest_log_photo_abs_path(company_id, id, now)
    File.mkdir_p!(Path.dirname(abs))
    File.cp!(photo_src(photo), abs)
    Path.relative_to(abs, uploads_dir())
  rescue
    e ->
      # A missing picture is worth far less than a missing row. Keep the row.
      Logger.error("punch ingest log photo copy failed: #{Exception.message(e)}")
      nil
  end

  # Repo.insert returns {:error, changeset} without raising, so the tuple needs
  # handling here; the raising cases (a check-constraint violation with no
  # check_constraint/3 on the changeset raises Postgrex.Error / ConstraintError)
  # are caught by the rescue on log_ingest/3 above.
  defp insert_ingest_log(attrs) do
    %PunchIngestLog{}
    |> PunchIngestLog.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, log} ->
        {:ok, log}

      {:error, reason} ->
        Logger.error("punch ingest log insert failed: #{inspect(reason)}")
        :error
    end
  end

  defp outcome_and_reason({:ok, _}), do: {"accepted", nil}
  defp outcome_and_reason({:replayed, _}), do: {"replayed", nil}
  defp outcome_and_reason({:error, :duplicate}), do: {"duplicate", nil}
  defp outcome_and_reason({:error, :duplicate, _employee_id}), do: {"duplicate", nil}
  defp outcome_and_reason({:error, reason}), do: {"rejected", reason_string(reason)}
  defp outcome_and_reason({:error, reason, _employee_id}), do: {"rejected", reason_string(reason)}

  # `reason` is check-constrained to this list. Anything else is stored as
  # "invalid" rather than violating the constraint, raising, being swallowed by
  # the rescue, and losing the row — the one failure this table cannot have.
  # It is also what makes String.to_existing_atom/1 below safe.
  @log_reasons ~w(not_found inactive too_large missing_photo future invalid revoked)

  defp reason_string(reason) do
    s = to_string(reason)
    if s in @log_reasons, do: s, else: "invalid"
  end

  defp log_status_atom("accepted", _), do: :accepted
  defp log_status_atom("replayed", _), do: :accepted
  defp log_status_atom("duplicate", _), do: :duplicate
  defp log_status_atom("rejected", reason), do: String.to_existing_atom(reason)

  defp log_time_attendence_id({:ok, %TimeAttend{id: id}}), do: id
  defp log_time_attendence_id({:replayed, %TimeAttend{id: id}}), do: id
  defp log_time_attendence_id(_), do: nil

  # The happy path reads the employee off the attendance row.
  defp log_employee_id({:ok, %TimeAttend{employee_id: id}}, _raw, _company_id), do: id
  defp log_employee_id({:replayed, %TimeAttend{employee_id: id}}, _raw, _company_id), do: id

  # insert_punch/6 already resolved and activated the employee, so take the id
  # off the tag instead of resolving the badge a second time.
  defp log_employee_id({:error, _reason, employee_id}, _raw, _company_id), do: employee_id

  # :duplicate and :inactive resolved an employee but produced no row and carry
  # no tag, so they are the only two outcomes that pay for an extra lookup.
  defp log_employee_id({:error, reason}, raw, company_id)
       when reason in [:duplicate, :inactive] do
    case get_company_employee(raw, company_id) do
      %Employee{id: id} -> id
      _ -> nil
    end
  end

  # Everything decided before the employee lookup — missing_photo, too_large,
  # future, an unparseable punched_at, not_found — has no employee to name.
  # employee_id_raw still holds whatever the phone sent.
  defp log_employee_id(_result, _raw, _company_id), do: nil

  defp parsed_or_nil(raw) do
    case parse_punched_at(raw) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  # employee_id and client_id are unvalidated client strings. varchar(255)
  # would raise on a long one, the rescue above would swallow it, and the log
  # row would be lost for exactly the malformed POST worth seeing.
  defp truncate_field(nil), do: nil
  defp truncate_field(s) when is_binary(s), do: String.slice(s, 0, @raw_field_limit)
  defp truncate_field(other), do: other |> to_string() |> String.slice(0, @raw_field_limit)

  @doc """
  Records a POST refused with 401 because the device is revoked.

  Always returns `:ok`; the caller is an auth plug and must send its 401
  regardless. No photo is copied — the useful fact is "this phone is unpaired",
  not the face.
  """
  def log_revoked_attempt(%PunchDevice{} = device, params) do
    raw = to_string(params["employee_id"] || "")

    insert_ingest_log(%{
      id: Ecto.UUID.generate(),
      inserted_at: DateTime.utc_now(),
      company_id: device.company_id,
      punch_device_id: device.id,
      employee_id: revoked_employee_id(raw, device.company_id),
      employee_id_raw: truncate_field(raw),
      client_id: truncate_field(params["client_id"]),
      punched_at: parsed_or_nil(params["punched_at"]),
      outcome: "rejected",
      reason: "revoked",
      http_status: http_status_for(:revoked)
    })

    :ok
  rescue
    e ->
      # Same contract as log_ingest/3, for the same reason and one layer earlier:
      # these are raw multipart params, so a repeated or nested field can make
      # `params["employee_id"]` a list or a map and `to_string/1` raise. Without
      # this the plug would 500 and the APK would retry a punch it should drop.
      Logger.error("punch revoked log raised: #{Exception.message(e)}")
      :ok
  end

  defp revoked_employee_id(raw, company_id) do
    case get_company_employee(raw, company_id) do
      %Employee{id: id} -> id
      _ -> nil
    end
  end
end
