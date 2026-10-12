defmodule FullCircle.BankPayment.Dismissal do
  use FullCircle.Schema
  import Ecto.Changeset
  use Gettext, backend: FullCircleWeb.Gettext

  # "Paid outside file": a Payment paid by cheque or manual transfer.
  schema "bank_payment_dismissals" do
    belongs_to :company, FullCircle.Sys.Company
    belongs_to :payment, FullCircle.BillPay.Payment
    belongs_to :user, FullCircle.UserAccounts.User
    field :note, :string
    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(d, attrs) do
    d
    |> cast(attrs, [:company_id, :payment_id, :user_id, :note])
    |> validate_required([:company_id, :payment_id, :user_id])
    |> validate_length(:note, max: 200)
    |> unique_constraint(:payment_id,
      name: :bank_payment_dismissals_payment_id_index,
      message: gettext("is already marked paid outside file")
    )
  end
end
