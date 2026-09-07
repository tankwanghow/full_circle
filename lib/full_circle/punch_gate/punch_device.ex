defmodule FullCircle.PunchGate.PunchDevice do
  use FullCircle.Schema
  import Ecto.Changeset
  use Gettext, backend: FullCircleWeb.Gettext

  schema "punch_devices" do
    field :name, :string
    field :token_hash, :string
    field :revoked_at, :utc_datetime
    field :last_seen_at, :utc_datetime
    belongs_to :company, FullCircle.Sys.Company
    belongs_to :paired_by_user, FullCircle.UserAccounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(device, attrs) do
    device
    |> cast(attrs, [
      :name,
      :token_hash,
      :revoked_at,
      :last_seen_at,
      :company_id,
      :paired_by_user_id
    ])
    |> validate_required([:name, :token_hash, :company_id])
    |> unique_constraint([:company_id, :name],
      name: :punch_devices_company_id_name_index,
      message: gettext("has already been taken")
    )
  end
end
