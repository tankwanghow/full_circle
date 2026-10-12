defmodule FullCircle.BankPayment.Download do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "bank_payment_downloads" do
    belongs_to :batch, FullCircle.BankPayment.Batch
    belongs_to :user, FullCircle.UserAccounts.User
    field :reason, :string
    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(d, attrs) do
    d
    |> cast(attrs, [:batch_id, :user_id, :reason])
    |> validate_required([:batch_id, :user_id])
  end
end
