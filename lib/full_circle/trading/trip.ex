defmodule FullCircle.Trading.Trip do
  use FullCircle.Schema
  import Ecto.Changeset

  @transport_modes ~w(company_own agent customer_arranged)
  @statuses ~w(draft planned completed cancelled)

  schema "trading_trips" do
    field :date, :date
    field :transport_mode, :string
    field :status, :string, default: "draft"
    field :notes, :string
    field :reference_no, :string

    field :good_name, :string, virtual: true
    field :transport_agent_name, :string, virtual: true

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :good, FullCircle.Product.Good
    belongs_to :transport_agent, FullCircle.Accounting.Contact

    has_many :loads, FullCircle.Trading.TripLoad, on_replace: :delete, on_delete: :delete_all
    has_many :drops, FullCircle.Trading.TripDrop, on_replace: :delete, on_delete: :delete_all

    timestamps(type: :utc_datetime)
  end

  def transport_modes, do: @transport_modes
  def statuses, do: @statuses

  def changeset(trip, attrs) do
    trip
    |> cast(attrs, [
      :date,
      :transport_mode,
      :status,
      :notes,
      :reference_no,
      :company_id,
      :good_id,
      :transport_agent_id,
      :good_name,
      :transport_agent_name
    ])
    |> cast_assoc(:loads, with: &FullCircle.Trading.TripLoad.changeset/2)
    |> cast_assoc(:drops, with: &FullCircle.Trading.TripDrop.changeset/2)
    |> validate_required([:date, :transport_mode, :status, :company_id, :good_id])
    |> validate_inclusion(:transport_mode, @transport_modes)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:company_id)
    |> foreign_key_constraint(:good_id)
    |> foreign_key_constraint(:transport_agent_id)
  end
end
