defmodule FullCircle.ReceiveFund.ReceivedCheque do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers
  import FullCircleWeb.Gettext

  schema "received_cheques" do
    field :_persistent_id, :integer
    field :bank, :string
    field :due_date, :date
    field :state, :string
    field :city, :string
    field :cheque_no, :string
    field :amount, :decimal, default: 0

    belongs_to :receipt, FullCircle.ReceiveFund.Receipt
    belongs_to :deposit, FullCircle.Cheque.Deposit
    belongs_to :return_cheque, FullCircle.Cheque.ReturnCheque

    field :delete, :boolean, virtual: true, default: false
  end

  @doc false
  def changeset(cheque, attrs) do
    cheque
    |> cast(attrs, [
      :_persistent_id,
      :id,
      :bank,
      :due_date,
      :state,
      :city,
      :cheque_no,
      :amount,
      :deposit_id,
      :return_cheque_id,
      :delete
    ])
    |> validate_required([:bank, :due_date, :cheque_no, :amount])
    |> validate_date(:due_date, before: Timex.shift(Timex.today, days: 90))
    |> validate_date(:due_date, after: Timex.shift(Timex.today, days: -90))
    |> validate_number(:amount, greater_than: 0)
    |> validate_cannot_update_deposited()
    |> validate_cannot_update_returned()
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

  defp validate_cannot_update_deposited(cs) do
    if is_nil(fetch_field!(cs, :deposit_id)) do
      cs
    else
      add_error(cs, :bank, gettext("Deposited!"))
    end
  end

  defp validate_cannot_update_returned(cs) do
    if is_nil(fetch_field!(cs, :return_cheque_id)) do
      cs
    else
      add_error(cs, :bank, gettext("Returned!"))
    end
  end
end
