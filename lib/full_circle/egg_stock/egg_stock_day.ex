defmodule FullCircle.EggStock.EggStockDay do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "egg_stock_days" do
    field :stock_date, :date
    field :opening_bal, :map, default: %{}
    field :closing_bal, :map, default: %{}
    field :note, :string
    field :ungraded_bal, :integer, default: 0
    field :expired, :map, default: %{}

    belongs_to :company, FullCircle.Sys.Company

    has_many :egg_stock_day_details, FullCircle.EggStock.EggStockDayDetail, on_replace: :delete

    field :production, :map, virtual: true, default: %{}
    field :percentage, :map, virtual: true, default: %{}

    timestamps(type: :utc_datetime)
  end

  def changeset(day, attrs) do
    day
    |> cast(attrs, [
      :stock_date,
      :opening_bal,
      :closing_bal,
      :note,
      :ungraded_bal,
      :expired,
      :company_id
    ])
    |> validate_required([:stock_date, :company_id])
    |> cast_assoc(:egg_stock_day_details)
    |> unique_constraint(:stock_date,
      name: :egg_stock_days_unique_date_in_company,
      message: "already exists for this company"
    )
  end
end
