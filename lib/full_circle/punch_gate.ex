defmodule FullCircle.PunchGate do
  import Ecto.Query, warn: false
  alias FullCircle.Repo
  alias FullCircle.PunchGate.PunchDevice
  alias FullCircle.Authorization

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
end
