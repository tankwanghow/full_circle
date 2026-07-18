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
    # System-generated unique trip no (TRP-000001) via gapless_doc_ids
    field :reference_no, :string
    # Lorry / plate number for the haul
    field :vehicle_number, :string

    field :transport_agent_name, :string, virtual: true

    belongs_to :company, FullCircle.Sys.Company
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
      :vehicle_number,
      :company_id,
      :transport_agent_id,
      :transport_agent_name
    ])
    |> cast_assoc(:loads, with: &FullCircle.Trading.TripLoad.changeset/2)
    |> cast_assoc(:drops, with: &FullCircle.Trading.TripDrop.changeset/2)
    |> validate_required([:date, :transport_mode, :status, :company_id, :reference_no])
    |> validate_inclusion(:transport_mode, @transport_modes)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:company_id, :reference_no],
      name: :trading_trips_unique_reference_no_per_company
    )
    |> foreign_key_constraint(:company_id)
    |> foreign_key_constraint(:transport_agent_id)
  end

  @doc "Distinct goods on loads and drops (preloaded or not)."
  def goods(%__MODULE__{loads: loads, drops: drops}) when is_list(loads) and is_list(drops) do
    (Enum.map(loads, & &1.good) ++ Enum.map(drops, & &1.good))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
  end

  def goods(_), do: []
end
