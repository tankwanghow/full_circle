defmodule FullCircle.Product.Delivery do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers
  use Gettext, backend: FullCircleWeb.Gettext

  schema "deliveries" do
    field :delivery_no, :string
    field :descriptions, :string
    field :delivery_date, :date
    field :lorry, :string
    field :delivery_man_tags, :string
    field :delivery_wages_tags, :string

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :customer, FullCircle.Accounting.Contact
    belongs_to :shipper, FullCircle.Accounting.Contact

    has_many :delivery_details, FullCircle.Product.DeliveryDetail, on_replace: :delete

    field :customer_name, :string, virtual: true
    field :shipper_name, :string, virtual: true

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :delivery_date,
      :lorry,
      :descriptions,
      :delivery_man_tags,
      :delivery_wages_tags,
      :company_id,
      :shipper_id,
      :shipper_name,
      :customer_id,
      :customer_name,
      :delivery_no
    ])
    |> fill_today(:delivery_date)
    |> validate_required([
      :delivery_date,
      :company_id,
      :delivery_no
    ])
    |> validate_date(:delivery_date, days_before: 2)
    |> validate_date(:delivery_date, days_after: 2)
    |> validate_length(:descriptions, max: 230)
    |> unsafe_validate_unique([:delivery_no, :company_id], FullCircle.Repo,
      message: gettext("Delivery No already in company")
    )
    |> cast_assoc(:delivery_details)
  end
end
