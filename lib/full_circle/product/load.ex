defmodule FullCircle.Product.Load do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers
  import FullCircleWeb.Gettext

  schema "loads" do
    field :load_no, :string
    field :descriptions, :string
    field :load_date, :date
    field :lorry, :string
    field :loader_tags, :string
    field :loader_wages_tags, :string

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :supplier, FullCircle.Accounting.Contact
    belongs_to :shipper, FullCircle.Accounting.Contact

    has_many :load_details, FullCircle.Product.LoadDetail, on_replace: :delete

    field :supplier_name, :string, virtual: true
    field :shipper_name, :string, virtual: true

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(load, attrs) do
    load
    |> cast(attrs, [
      :load_date,
      :lorry,
      :descriptions,
      :loader_tags,
      :loader_wages_tags,
      :company_id,
      :shipper_id,
      :shipper_name,
      :supplier_id,
      :supplier_name,
      :load_no
    ])
    |> fill_today(:load_date)
    |> validate_required([
      :load_date,
      :company_id,
      :load_no
    ])
    |> validate_date(:load_date, days_before: 2)
    |> validate_date(:load_date, days_after: 2)
    |> validate_length(:descriptions, max: 230)
    |> unsafe_validate_unique([:load_no, :company_id], FullCircle.Repo,
      message: gettext("Load No already in company")
    )
    |> cast_assoc(:load_details)
  end
end
