defmodule FullCircle.EInvMetas.EInvMeta do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "e_inv_metas" do
    field :environment, :string, default: "production"
    field :sandbox, :map, default: %{}
    field :production, :map, default: %{}
    field :paths, :map, default: %{}
    field :unit_code_map, :map, default: %{}
    field :token, :string

    belongs_to(:company, FullCircle.Sys.Company, type: :binary_id)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(e_inv_meta, attrs) do
    e_inv_meta
    |> cast(attrs, [
      :environment,
      :sandbox,
      :production,
      :paths,
      :unit_code_map,
      :token,
      :company_id
    ])
    |> validate_required([
      :environment,
      :company_id
    ])
    |> validate_inclusion(:environment, ["sandbox", "production"])
    |> clear_token_on_env_change()
  end

  defp clear_token_on_env_change(changeset) do
    if get_change(changeset, :environment) do
      put_change(changeset, :token, nil)
    else
      changeset
    end
  end
end
