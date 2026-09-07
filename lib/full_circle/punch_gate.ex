defmodule FullCircle.PunchGate do
  import Ecto.Query, warn: false
  alias FullCircle.Repo
  alias FullCircle.PunchGate.PunchDevice
  alias FullCircle.Authorization
  alias FullCircle.HR.{TimeAttend, Employee}

  @flags ~w(1_IN_1 1_OUT_1 2_IN_2 2_OUT_2 3_IN_3 3_OUT_3)
  @dup_seconds 180
  @future_leeway_seconds 120
  @max_photo_bytes 300_000

  def hash_token(plain) when is_binary(plain) do
    :crypto.hash(:sha256, plain) |> Base.encode16(case: :lower)
  end

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

  def get_active_device_by_token(plain) when is_binary(plain) do
    from(d in PunchDevice,
      where: d.token_hash == ^hash_token(plain),
      where: is_nil(d.revoked_at),
      preload: [:company]
    )
    |> Repo.one()
  end

  def list_devices(company, user) do
    case Authorization.can?(user, :manage_punch_device, company) do
      true ->
        from(d in PunchDevice,
          where: d.company_id == ^company.id,
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
    punched_at = attrs["punched_at"] || attrs[:punched_at]
    photo = attrs["photo"] || attrs[:photo]

    with :ok <- validate_photo(photo),
         {:ok, punched_at} <- parse_punched_at(punched_at),
         :ok <- validate_not_future(punched_at),
         %Employee{} = emp <- get_company_employee(employee_id, company.id),
         :ok <- validate_active(emp) do
      case existing_client(device.id, client_id) do
        %TimeAttend{} = ta ->
          {:ok, ta}

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
  end

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

  def rebuild_day_flags(employee_id, company, %DateTime{} = punched_at) do
    tz = company.timezone
    {:ok, local} = DateTime.shift_zone(punched_at, tz)
    d = DateTime.to_date(local)
    {:ok, start_local} = DateTime.new(d, ~T[00:00:00], tz)
    start_utc = DateTime.shift_zone!(start_local, "Etc/UTC")
    end_utc = DateTime.add(start_utc, 86400, :second)

    rows =
      from(ta in TimeAttend,
        where: ta.employee_id == ^employee_id,
        where: ta.company_id == ^company.id,
        where: ta.punch_time >= ^start_utc and ta.punch_time < ^end_utc,
        order_by: [asc: ta.punch_time, asc: ta.flag]
      )
      |> Repo.all()

    rows
    |> Enum.with_index()
    |> Enum.each(fn {ta, i} ->
      flag = Enum.at(@flags, rem(i, length(@flags)))

      if ta.flag != flag do
        ta |> Ecto.Changeset.change(%{flag: flag}) |> Repo.update!()
      end
    end)

    :ok
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
      rebuild_day_flags(emp.id, company, punched_at)
      {:ok, Repo.get!(TimeAttend, ta.id)}
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
        resolve_client_conflict(cs, device.id, client_id)

      {:error, _, reason, _} when is_atom(reason) ->
        {:error, reason}

      {:error, _, _reason, _} ->
        {:error, :invalid}
    end
  end

  defp resolve_client_conflict(%Ecto.Changeset{} = cs, device_id, client_id) do
    unique? =
      case Keyword.get(cs.errors, :client_id) do
        {_msg, opts} -> opts[:constraint] == :unique
        _ -> false
      end

    if unique? do
      case existing_client(device_id, client_id) do
        %TimeAttend{} = ta -> {:ok, Repo.preload(ta, :employee)}
        nil -> {:error, :invalid}
      end
    else
      {:error, :invalid}
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
    Repo.get_by(Employee, id: id, company_id: company_id) || {:error, :not_found}
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
end
