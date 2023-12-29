defmodule FullCircle.Product.Order do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers
  import FullCircleWeb.Gettext

  schema "orders" do
    field :order_no, :string
    field :descriptions, :string
    field :order_date, :date
    field :etd_date, :date

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :customer, FullCircle.Accounting.Contact

    has_many :order_details, FullCircle.Product.OrderDetail, on_replace: :delete

    field :customer_name, :string, virtual: true

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(order, attrs) do
    order
    |> cast(attrs, [
      :order_date,
      :etd_date,
      :descriptions,
      :company_id,
      :customer_id,
      :customer_name,
      :order_no
    ])
    |> fill_today(:order_date)
    |> validate_required([
      :order_date,
      :etd_date,
      :company_id,
      :customer_name,
      :order_no
    ])
    |> validate_date(:order_date, days_before: 2)
    |> validate_date(:order_date, days_after: 2)
    |> validate_id(:customer_name, :customer_id)
    |> unsafe_validate_unique([:order_no, :company_id], FullCircle.Repo,
      message: gettext("Order No already in company")
    )
    |> cast_assoc(:order_details)
  end
end
