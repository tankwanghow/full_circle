defmodule FullCircle.ReceiveFunds.Receipt do
  use Ecto.Schema
  import Ecto.Changeset
  import FullCircle.Helpers
  import FullCircleWeb.Gettext

  schema "receipts" do
    field :receipt_no, :string
    field :receipt_date, :date
    belongs_to :contact_id, FullCircle.Accounting.Contact
    field :descriptions, :string
    belongs_to :cash_or_bank_id, FullCircle.Accounting.Account
    field :receipt_amount, :decimal, default: 0
    belongs_to :company, FullCircle.Sys.Company

    has_many :receipt_details, FullCircle.ReceiveFunds.ReceiptDetail, on_replace: :delete
    has_many :received_cheques, FullCircle.ReceiveFunds.ReceivedCheque, on_replace: :delete

    has_many :receipt_transaction_matchers, FullCircle.ReceiveFunds.ReceiptTransactionMatcher,
      on_replace: :delete

    field :contact_name, :string, virtual: true
    field :cash_or_bank_name, :string, virtual: true
    field :receipt_good_amount, :decimal, virtual: true, default: 0
    field :receipt_tax_amount, :decimal, virtual: true, default: 0

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [
      :receipt_date,
      :descriptions,
      :company_id,
      :contact_id,
      :contact_name,
      :receipt_no,
      :cash_or_bank_name,
      :cash_or_bank_id,
      :receipt_amount
    ])
    |> fill_default_date()
    |> validate_required([
      :receipt_date,
      :company_id,
      :contact_name,
      :receipt_no,
      :cash_or_bank_name,
      :receipt_amount
    ])
    |> validate_id(:contact_name, :contact_id)
    |> unsafe_validate_unique([:receipt_no, :company_id], FullCircle.Repo,
      message: gettext("receipt no already in company")
    )
    |> cast_assoc(:receipt_details)
    |> compute_fields()
  end

  def compute_fields(changeset) do
    changeset =
      if is_nil(get_change(changeset, :receipt_details)) do
        compute_unchange_fields(changeset)
      else
        compute_change_field(changeset)
      end

    if Decimal.lt?(fetch_field!(changeset, :receipt_amount), "0.01") do
      add_error(changeset, :receipt_amount, gettext("must be greater than 0.01"))
    else
      changeset
    end
  end

  defp compute_change_field(changeset) do
    invds = get_change(changeset, :receipt_details)

    iga =
      Enum.reduce(invds, 0, fn x, acc ->
        Decimal.add(
          acc,
          if(!fetch_field!(x, :delete),
            do: fetch_field!(x, :good_amount),
            else: 0
          )
        )
      end)

    ita =
      Enum.reduce(invds, 0, fn x, acc ->
        Decimal.add(
          acc,
          if(!fetch_field!(x, :delete), do: fetch_field!(x, :tax_amount), else: 0)
        )
      end)

    ia =
      Enum.reduce(invds, 0, fn x, acc ->
        Decimal.add(
          acc,
          if(!fetch_field!(x, :delete), do: fetch_field!(x, :amount), else: 0)
        )
      end)

    changeset
    |> put_change(:receipt_good_amount, iga)
    |> put_change(:receipt_tax_amount, ita)
    |> put_change(:receipt_amount, ia)
  end

  defp compute_unchange_fields(changeset)
       when is_struct(changeset.data.receipt_details, Ecto.Association.NotLoaded) do
    changeset
  end

  defp compute_unchange_fields(changeset) do
    iga =
      Enum.reduce(changeset.data.receipt_details, 0, fn x, acc ->
        Decimal.add(acc, x.good_amount)
      end)

    ita =
      Enum.reduce(changeset.data.receipt_details, 0, fn x, acc ->
        Decimal.add(acc, x.tax_amount)
      end)

    ia =
      Enum.reduce(changeset.data.receipt_details, 0, fn x, acc ->
        Decimal.add(x.tax_amount, x.good_amount) |> Decimal.add(acc)
      end)

    changeset
    |> put_change(:receipt_good_amount, iga)
    |> put_change(:receipt_tax_amount, ita)
    |> put_change(:receipt_amount, ia)
  end

  def fill_computed_field(receipt) do
    receipt =
      Map.merge(receipt, %{
        receipt_details:
          Enum.map(receipt.receipt_details, fn x ->
            gamt =
              Decimal.mult(x.quantity, x.unit_price)
              |> Decimal.round(2)

            tamt =
              Decimal.mult(x.quantity, x.unit_price)
              |> Decimal.mult(x.tax_rate)
              |> Decimal.round(2)

            Map.merge(x, %{
              good_amount: gamt,
              tax_amount: tamt,
              amount: Decimal.add(tamt, gamt)
            })
          end)
      })

    receipt =
      receipt
      |> Map.merge(%{
        receipt_good_amount:
          Enum.reduce(receipt.receipt_details, 0, fn x, acc ->
            Decimal.add(acc, x.good_amount)
          end)
      })
      |> Map.merge(%{
        receipt_tax_amount:
          Enum.reduce(receipt.receipt_details, 0, fn x, acc ->
            Decimal.add(acc, x.tax_amount)
          end)
      })

    Map.merge(receipt, %{
      receipt_amount: Decimal.add(receipt.receipt_good_amount, receipt.receipt_tax_amount)
    })
  end

  defp fill_default_date(changeset) do
    if is_nil(fetch_field!(changeset, :receipt_date)) do
      changeset
      |> put_change(:receipt_date, Date.utc_today())
    else
      changeset
    end
  end
end
