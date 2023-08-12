defmodule FullCircle.ReceiveFund.ReceivedCheque do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "received_cheques" do
    field :_persistent_id, :integer
    field :bank, :string
    field :due_date, :date
    field :state, :string
    field :city, :string
    field :cheque_no, :string
    field :amount, :decimal, default: 0

    belongs_to :receipt, FullCircle.ReceiveFund.Receipt

    # has_one :deposit
    # has_one :return_cheque_note

    field :delete, :boolean, virtual: true, default: false
  end

  @doc false
  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [
      :_persistent_id,
      :bank,
      :due_date,
      :state,
      :city,
      :cheque_no,
      :amount,
      :delete
    ])
    |> validate_required([:bank, :due_date, :cheque_no, :amount])
    |> validate_number(:amount, greater_than: 0)
    |> maybe_mark_for_deletion()
  end

  defp maybe_mark_for_deletion(%{data: %{id: nil}} = changeset), do: changeset

  defp maybe_mark_for_deletion(changeset) do
    if get_change(changeset, :delete) do
      %{changeset | action: :delete}
    else
      changeset
    end
  end
end
