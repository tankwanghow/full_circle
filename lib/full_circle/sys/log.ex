defmodule FullCircle.Sys.Log do
  use Ecto.Schema
  import Ecto.Changeset

  schema "logs" do
    field :action, :string
    field :delta, :string
    field :entity, :string
    field :entity_id, :integer
    belongs_to :user, FullCircle.UserAccounts.User
    belongs_to :company, FullCircle.Sys.Company

    field :email, :string, virtual: true

    timestamps(updated_at: false, type: :utc_datetime)
  end

  @doc false
  def changeset(log, attrs) do
    log
    |> cast(attrs, [:entity, :entity_id, :action, :delta, :company_id, :user_id])
    |> validate_required([:entity, :entity_id, :action, :delta, :company_id, :user_id])
  end
end
