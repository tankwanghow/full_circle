defmodule FullCircle.Billing.PurInvoice do
  use Ecto.Schema
  import Ecto.Changeset
  import FullCircle.Helpers
  import FullCircleWeb.Gettext

  schema "pur_invoices" do
    field :pur_invoice_no, :string
    field :supplier_invoice_no, :string
    field :descriptions, :string
    field :due_date, :date
    field :pur_invoice_date, :date
    field :tags, :string

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :contact, FullCircle.Accounting.Contact

    has_many :pur_invoice_details, FullCircle.Billing.PurInvoiceDetail, on_replace: :delete

    field :contact_name, :string, virtual: true
    field :pur_invoice_amount, :decimal, virtual: true, default: 0
    field :pur_invoice_good_amount, :decimal, virtual: true, default: 0
    field :pur_invoice_tax_amount, :decimal, virtual: true, default: 0

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(pur_invoice, attrs) do
    pur_invoice
    |> cast(attrs, [
      :pur_invoice_date,
      :supplier_invoice_no,
      :due_date,
      :descriptions,
      :tags,
      :company_id,
      :contact_id,
      :contact_name,
      :pur_invoice_no
    ])
    |> fill_default_date()
    |> validate_required([
      :pur_invoice_date,
      :supplier_invoice_no,
      :due_date,
      :company_id,
      :contact_name,
      :pur_invoice_no
    ])
    |> validate_id(:contact_name, :contact_id)
    |> unsafe_validate_unique([:pur_invoice_no, :company_id], FullCircle.Repo,
      message: gettext("pur_invoice no already in company")
    )
    |> cast_assoc(:pur_invoice_details)
    |> compute_fields()
  end

  def compute_fields(changeset) do
    changeset =
      if is_nil(get_change(changeset, :pur_invoice_details)) do
        compute_unchange_fields(changeset)
      else
        compute_change_field(changeset)
      end

    if Decimal.lt?(fetch_field!(changeset, :pur_invoice_amount), "0.01") do
      add_error(changeset, :pur_invoice_amount, gettext("must be greater than 0.01"))
    else
      changeset
    end
  end

  defp compute_change_field(changeset) do
    invds = get_change(changeset, :pur_invoice_details)

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
    |> put_change(:pur_invoice_good_amount, iga)
    |> put_change(:pur_invoice_tax_amount, ita)
    |> put_change(:pur_invoice_amount, ia)
  end

  defp compute_unchange_fields(changeset)
       when is_struct(changeset.data.pur_invoice_details, Ecto.Association.NotLoaded) do
    changeset
  end

  defp compute_unchange_fields(changeset) do
    iga =
      Enum.reduce(changeset.data.pur_invoice_details, 0, fn x, acc ->
        Decimal.add(acc, x.good_amount)
      end)

    ita =
      Enum.reduce(changeset.data.pur_invoice_details, 0, fn x, acc ->
        Decimal.add(acc, x.tax_amount)
      end)

    ia =
      Enum.reduce(changeset.data.pur_invoice_details, 0, fn x, acc ->
        Decimal.add(x.tax_amount, x.good_amount) |> Decimal.add(acc)
      end)

    changeset
    |> put_change(:pur_invoice_good_amount, iga)
    |> put_change(:pur_invoice_tax_amount, ita)
    |> put_change(:pur_invoice_amount, ia)
  end

  def fill_computed_field(pur_invoice) do
    pur_invoice =
      Map.merge(pur_invoice, %{
        pur_invoice_details:
          Enum.map(pur_invoice.pur_invoice_details, fn x ->
            gamt =
              Decimal.mult(x.quantity, x.unit_price)
              |> Decimal.add(x.discount)
              |> Decimal.round(2)

            tamt =
              Decimal.mult(x.quantity, x.unit_price)
              |> Decimal.add(x.discount)
              |> Decimal.mult(x.tax_rate)
              |> Decimal.round(2)

            Map.merge(x, %{
              good_amount: gamt,
              tax_amount: tamt,
              amount: Decimal.add(tamt, gamt)
            })
          end)
      })

    pur_invoice =
      pur_invoice
      |> Map.merge(%{
        pur_invoice_good_amount:
          Enum.reduce(pur_invoice.pur_invoice_details, 0, fn x, acc ->
            Decimal.add(acc, x.good_amount)
          end)
      })
      |> Map.merge(%{
        pur_invoice_tax_amount:
          Enum.reduce(pur_invoice.pur_invoice_details, 0, fn x, acc ->
            Decimal.add(acc, x.tax_amount)
          end)
      })

    Map.merge(pur_invoice, %{
      pur_invoice_amount: Decimal.add(pur_invoice.pur_invoice_good_amount, pur_invoice.pur_invoice_tax_amount)
    })
  end

  defp fill_default_date(changeset) do
    if is_nil(fetch_field!(changeset, :pur_invoice_date)) do
      changeset
      |> put_change(:pur_invoice_date, Date.utc_today())
      |> put_change(:due_date, Date.utc_today())
    else
      changeset
    end
  end
end
