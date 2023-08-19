defmodule FullCircle.ReceiveFund.ReceivedCheque do
  use FullCircle.Schema
  import Ecto.Changeset
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

    field :deposit_date, :date
    belongs_to :deposit_account, FullCircle.Accounting.Account

    field :return_cheque_date, :date
    belongs_to :return_from_account, FullCircle.Accounting.Account
    belongs_to :return_to_account, FullCircle.Accounting.Account

    field :deposit_to_account_name, :string, virtual: true
    field :return_from_account_name, :string, virtual: true
    field :return_to_account_name, :string, virtual: true

    field :delete, :boolean, virtual: true, default: false
  end

  @doc false
  def changeset(cheque, attrs) do
    cheque
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

  def deposit_changeset(cheque, attrs) do
    cheque
    |> cast(attrs, [
      :deposit_date,
      :deposit_account_name
    ])
    |> validate_required([:deposit_date, :deposit_account_name])
    |> validate_deposit_date()
  end

  defp validate_deposit_date(changeset) do
    due = fetch_field!(changeset, :due_date)
    dep = fetch_field!(changeset, :deposit_date)

    if Timex.diff(due, dep, :days) <= 0 do
      changeset
    else
      add_error(changeset, :deposit_date, gettext("must be greater than due_date"))
    end
  end
end
